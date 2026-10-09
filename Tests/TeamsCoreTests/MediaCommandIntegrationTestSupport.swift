import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

enum CommandUnderTest: CaseIterable {
    case microphone, camera, hand

    var control: MediaControl {
        switch self {
        case .microphone: return .microphone
        case .camera: return .camera
        case .hand: return .hand
        }
    }

    var button: AXUIElement {
        switch self {
        case .microphone: return AXUIElementCreateApplication(11)
        case .camera: return AXUIElementCreateApplication(13)
        case .hand: return AXUIElementCreateApplication(14)
        }
    }

    var changedReason: String {
        switch self {
        case .microphone: return "microphone_state_changed"
        case .camera: return "camera_state_changed"
        case .hand: return "hand_state_changed"
        }
    }

    func state(active: Bool) -> String {
        switch self {
        case .microphone: return active ? "unmuted" : "muted"
        case .camera: return active ? "on" : "off"
        case .hand: return active ? "raised" : "lowered"
        }
    }

    /// A nil target invokes toggle. Concrete types keep every production adapter in the path.
    func run(_ harness: MediaCommandHarness, target: Bool? = nil, timings: CommandTimings? = nil) throws -> CommandTestResult {
        let environment = harness.environment
        switch self {
        case .microphone:
            let result: MicrophoneActionResult
            if let target {
                result = try TeamsMicrophoneCommands.set(target ? .unmuted : .muted, environment: environment)
            } else {
                result = try TeamsMicrophoneCommands.toggle(environment: environment, timings: timings)
            }
            return CommandTestResult(state: result.state.rawValue, reason: result.reason, changed: result.changed,
                                     attempted: result.actionAttempted, focus: result.focusUnchanged,
                                     indices: result.windows.map(\.window), states: result.windows.map { $0.state.rawValue },
                                     excluded: result.excludedWindows, success: result.success)
        case .camera:
            let result: CameraActionResult
            if let target {
                result = try TeamsCameraCommands.set(target ? .on : .off, environment: environment)
            } else {
                result = try TeamsCameraCommands.toggle(environment: environment, timings: timings)
            }
            return CommandTestResult(state: result.state.rawValue, reason: result.reason, changed: result.changed,
                                     attempted: result.actionAttempted, focus: result.focusUnchanged,
                                     indices: result.windows.map(\.window), states: result.windows.map { $0.state.rawValue },
                                     excluded: result.excludedWindows, success: result.success)
        case .hand:
            let result: HandActionResult
            if let target {
                result = try TeamsHandCommands.set(target ? .raised : .lowered, environment: environment)
            } else {
                result = try TeamsHandCommands.toggle(environment: environment)
            }
            return CommandTestResult(state: result.state.rawValue, reason: result.reason, changed: result.changed,
                                     attempted: result.actionAttempted, focus: result.focusUnchanged,
                                     indices: result.windows.map(\.window), states: result.windows.map { $0.state.rawValue },
                                     excluded: result.excludedWindows, success: result.success)
        }
    }
}

struct CommandTestResult {
    let state: String
    let reason: String?
    let changed: Bool?
    let attempted: Bool
    let focus: Bool?
    let indices: [Int]
    let states: [String]
    let excluded: [ExcludedWindow]
    let success: Bool
}

/// Native elements are identity tokens; no attribute read or press reaches another process.
struct CommandFrame {
    var snapshot: TeamsSnapshot
    var values: [AXUIElement: [String: String]]
    var ready: Bool

    init(active: Bool, index: Int = 7, window: pid_t = 10, complete: Bool = true, ready: Bool = true) {
        let mic = ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: active ? "Mute mic" : "Unmute mic")
        let camera = ControlSnapshot(role: "AXButton", identifier: "video-button", label: active ? "Turn camera off" : "Turn camera on")
        let hand = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise your hand")
        let hangup = ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
        let marker = active ? ", Hand raised position 1" : ""
        let ownVideo = ControlSnapshot(role: "AXImage", identifier: "",
                                       label: "Myself video, Test User, Video is off\(marker), Has context menu")
        let handles = CallWindowHandles(application: .current, window: AXUIElementCreateApplication(window),
                                        microphones: [AXUIElementCreateApplication(11)], cameras: [AXUIElementCreateApplication(13)],
                                        hangups: [AXUIElementCreateApplication(12)], hands: [AXUIElementCreateApplication(14)],
                                        ownVideos: [AXUIElementCreateApplication(15)])
        snapshot = TeamsSnapshot(windows: [
            WindowSnapshot(index: index, controls: [mic, camera, hand, hangup, ownVideo]),
            WindowSnapshot(index: 12, controls: [hangup, ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")])
        ], complete: complete, focusUnchanged: true, handles: [index: handles])
        values = [:]
        for (element, control) in [(handles.microphones[0], mic), (handles.cameras[0], camera),
                                    (handles.hands[0], hand), (handles.hangups[0], hangup), (handles.ownVideos[0], ownVideo)] {
            values[element] = ["AXRole": control.role, "AXDOMIdentifier": control.identifier, "AXDescription": control.label]
        }
        self.ready = ready
    }
}

final class CommandAccessibilityStub: MediaAccessibilityClient {
    var frames: [CommandFrame]
    var uptime: TimeInterval = 100
    var readErrors: [Int: TeamsReadError] = [:]
    var directValues: [AXUIElement: [String: String]] = [:]
    var pressError = AXError.success
    var sameProcess = true
    var record: (String) -> Void = { _ in }
    var onRead: (() -> Void)?
    var onValueRead: (() -> Void)?
    var onPress: (() -> Void)?
    private var current: CommandFrame
    private(set) var reads: [(control: MediaControl, timeout: TimeInterval)] = []
    private(set) var pressed: [AXUIElement] = []
    private(set) var directReads: [AXUIElement] = []
    private(set) var readsAtPress = 0

    init(_ frames: [CommandFrame]) {
        precondition(!frames.isEmpty)
        self.frames = frames
        current = frames[0]
    }

    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        reads.append((control, timeout))
        record("sample")
        onRead?()
        if let error = readErrors[reads.count] { throw error }
        current = frames[min(reads.count - 1, frames.count - 1)]
        return current.snapshot
    }

    func generation(of application: NSRunningApplication) -> MediaProcessGeneration? {
        MediaProcessGeneration(pid: 123, launched: Date(timeIntervalSince1970: 1))
    }

    func processMatches(pid: pid_t, launched: Date) -> Bool {
        sameProcess && pid == 123 && launched == Date(timeIntervalSince1970: 1)
    }

    func canPress(_ element: AXUIElement) -> Bool { current.ready }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        directReads.append(element)
        onValueRead?()
        return (directValues[element]?[name] ?? current.values[element]?[name]).map { $0 as CFString }
    }

    func press(_ element: AXUIElement) -> AXError {
        record("press")
        pressed.append(element)
        readsAtPress = reads.count
        onPress?()
        return pressError
    }
}

final class MediaCommandHarness {
    let lifecycle: CommandLifecycleHarness
    let accessibility: CommandAccessibilityStub
    private(set) var waits = 0
    private(set) var waitDurations: [TimeInterval] = []
    var onWait: ((TimeInterval) -> Void)?

    init(_ frames: [CommandFrame]) throws {
        lifecycle = try CommandLifecycleHarness()
        accessibility = CommandAccessibilityStub(frames)
        accessibility.record = { [weak lifecycle] in lifecycle?.events.append($0) }
    }

    var environment: MediaActionEnvironment<LifecycleFocus> {
        MediaActionEnvironment(lifecycle: lifecycle.environment, makeAccessibility: {
            self.lifecycle.events.append("backend")
            return self.accessibility
        }, wait: { duration in
            self.lifecycle.events.append("wait")
            self.waits += 1
            self.waitDurations.append(duration)
            self.accessibility.uptime += duration
            self.onWait?(duration)
        })
    }

    func assertFinalized(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lifecycle.client.writes, [true, false], file: file, line: line)
        XCTAssertEqual(Array(lifecycle.events.suffix(5)), ["read", "write false", "verify false", "focus.read", "focus.stop"],
                       file: file, line: line)
        XCTAssertEqual(lifecycle.events.filter { $0 == "focus.stop" }.count, 1, file: file, line: line)
        lifecycle.assertUnlocked(file: file, line: line)
    }
}
