import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class NativeMediaBackendTests: XCTestCase {
    func testToggleUsesTwoDiscoveryReadsAndTwoFreshVerificationReads() throws {
        for initial in [MicrophoneState.muted, .unmuted] {
            let desired: MicrophoneState = initial == .muted ? .unmuted : .muted
            let client = FakeMediaAccessibility([
                mic(initial), mic(initial), mic(desired), mic(desired)
            ])
            client.label = initial == .muted ? "Unmute mic" : "Mute mic"
            let result = try MicrophoneController(backend: adapter(client)).toggle()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.state, desired)
            XCTAssertEqual(client.readCount, 4)
            XCTAssertEqual(client.presses, 1)
            XCTAssertEqual(client.readCountAtPress, 2)
            XCTAssertEqual(client.waits, 2)
        }
    }

    func testConcurrentChangeToDesiredStateStillAvoidsPressing() throws {
        let client = FakeMediaAccessibility([mic(.unmuted), mic(.muted)])
        let result = try MicrophoneController(backend: adapter(client)).toggle()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changed, false)
        XCTAssertFalse(result.actionAttempted)
        XCTAssertEqual(client.readCount, 2)
        XCTAssertEqual(client.presses, 0)
    }

    func testAlreadyRequestedStateStillNeedsOnlyOneRead() throws {
        let client = FakeMediaAccessibility([mic(.muted)])
        let result = try MicrophoneController(backend: adapter(client)).set(.muted)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.changed, false)
        XCTAssertEqual(client.readCount, 1)
        XCTAssertEqual(client.presses, 0)
    }

    func testHeldAmbiguousAndIncompletePreflightCannotUseEarlierDiscovery() throws {
        var held = mic(.unmuted)
        held = TeamsSnapshot(windows: [WindowSnapshot(index: 1, controls: held.windows[0].controls + [
            ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")
        ])], complete: true, focusUnchanged: true, handles: held.handles)
        let second = mic(.unmuted, index: 2, window: 20)
        let first = mic(.unmuted)
        let ambiguous = TeamsSnapshot(windows: first.windows + second.windows, complete: true,
                                      focusUnchanged: true, handles: first.handles.merging(second.handles) { a, _ in a })
        var duplicate = mic(.unmuted)
        duplicate.handles[1]!.microphones.append(AXUIElementCreateApplication(21))
        for snapshot in [held, ambiguous, duplicate, mic(.unmuted, complete: false)] {
            let client = FakeMediaAccessibility([first, snapshot])
            let backend = native(client)
            let initial = try backend.sample()
            _ = try backend.sample()
            assertRejected("preflight_failed") {
                try backend.press(targetID: initial.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.readCount, 2)
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testFailedReadInvalidatesPreviousPreflight() throws {
        let client = FakeMediaAccessibility([mic(.unmuted)])
        let backend = native(client)
        let initial = try backend.sample()
        client.failRead = true
        XCTAssertThrowsError(try backend.sample())
        assertRejected("preflight_failed") {
            try backend.press(targetID: initial.targetID!, expectedState: .unmuted)
        }
        XCTAssertEqual(client.presses, 0)
    }

    func testReplacingWindowButtonOrHangupChangesIdentity() throws {
        for replacement in [mic(.unmuted, window: 20), mic(.unmuted, button: 21), mic(.unmuted, hangup: 22)] {
            let client = FakeMediaAccessibility([mic(.unmuted), replacement])
            let backend = native(client)
            let original = try backend.sample()
            let fresh = try backend.sample()
            XCTAssertNotEqual(original.targetID, fresh.targetID)
            assertRejected("target_changed") {
                try backend.press(targetID: original.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testWindowReorderingRetainsExactTargetIdentity() throws {
        let client = FakeMediaAccessibility([mic(.unmuted), mic(.unmuted, index: 3)])
        let backend = native(client)
        let original = try backend.sample()
        let fresh = try backend.sample()
        XCTAssertEqual(original.targetID, fresh.targetID)
        try backend.press(targetID: original.targetID!, expectedState: .unmuted)
        XCTAssertEqual(client.presses, 1)
        XCTAssertEqual(client.readCount, 2)
    }

    func testChangedOrUnknownProcessGenerationCannotReuseDiscovery() throws {
        for generation in [MediaProcessGeneration(pid: 123, launched: Date(timeIntervalSince1970: 2)),
                           MediaProcessGeneration(pid: 124, launched: Date(timeIntervalSince1970: 1)), nil] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client)
            let original = try backend.sample()
            client.processGeneration = generation
            let fresh = try backend.sample()
            XCTAssertNotEqual(original.targetID, fresh.targetID)
            assertRejected(generation == nil ? "preflight_failed" : "target_changed") {
                try backend.press(targetID: original.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testDispatchWithoutPreparedDiscoveryIsRefused() {
        let client = FakeMediaAccessibility([mic(.unmuted)])
        assertRejected("preflight_failed") {
            try native(client).press(targetID: "missing", expectedState: .unmuted)
        }
        XCTAssertEqual(client.readCount, 0)
        XCTAssertEqual(client.presses, 0)
    }

    func testPreflightCannotBeReplayedAfterSuccessRejectionOrUncertainPress() throws {
        for outcome in ["success", "rejected", "uncertain"] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client)
            let sample = try backend.sample()
            if outcome == "rejected" { client.label = "Unmute mic" }
            if outcome == "uncertain" { client.pressError = .cannotComplete }
            if outcome == "success" {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            } else {
                XCTAssertThrowsError(try backend.press(targetID: sample.targetID!, expectedState: .unmuted))
            }
            assertRejected("preflight_failed") {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, outcome == "rejected" ? 0 : 1)
            XCTAssertEqual(client.readCount, 1)
        }
    }

    func testLatestSampleStateMustMatchExpectedState() throws {
        let client = FakeMediaAccessibility([mic(.muted)])
        let backend = native(client)
        let sample = try backend.sample()
        assertRejected("microphone_state_changed") {
            try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
        }
        XCTAssertEqual(client.presses, 0)
    }

    func testDirectReadRejectsChangedStateRoleOrButtonIdentifier() throws {
        for change in ["state", "role", "identifier"] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client)
            let sample = try backend.sample()
            if change == "state" { client.label = "Unmute mic" }
            if change == "role" { client.role = "AXStaticText" }
            if change == "identifier" { client.identifier = "participant-microphone" }
            assertRejected("microphone_state_changed") {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testProcessReplacementBeforeOrDuringDirectReadPreventsDispatch() throws {
        for duringRead in [false, true] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client)
            let sample = try backend.sample()
            if duringRead { client.replaceProcessDuringValueRead = true }
            else { client.sameProcess = false }
            assertRejected("target_changed") {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testDisabledControlAtDiscoveryOrDispatchIsRefused() throws {
        for disableBeforeSample in [false, true] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client)
            client.ready = !disableBeforeSample
            let sample = try backend.sample()
            client.ready = false
            assertRejected("control_unavailable") {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testFinalFocusCheckStillRefusesChangedOrUnknownFocus() throws {
        for focus: Bool? in [false, nil] {
            let client = FakeMediaAccessibility([mic(.unmuted)])
            let backend = native(client, focus: { focus })
            let sample = try backend.sample()
            assertRejected(focus == nil ? "focus_unavailable" : "focus_changed") {
                try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
            }
            XCTAssertEqual(client.presses, 0)
        }
    }

    func testExpiredCommandBudgetPreventsPreparedDispatch() throws {
        let client = FakeMediaAccessibility([mic(.unmuted)])
        let backend = native(client)
        let sample = try backend.sample()
        client.uptime = 8
        assertRejected("preflight_failed") {
            try backend.press(targetID: sample.targetID!, expectedState: .unmuted)
        }
        XCTAssertEqual(client.presses, 0)
    }

    func testVerificationStillRejectsReplacementCallAfterPress() throws {
        let client = FakeMediaAccessibility([mic(.unmuted), mic(.unmuted), mic(.muted, window: 20)])
        let result = try MicrophoneController(backend: adapter(client)).toggle()
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.actionAttempted)
        XCTAssertNil(result.changed)
        XCTAssertEqual(result.reason, "target_changed")
        XCTAssertEqual(client.readCount, 3)
        XCTAssertEqual(client.presses, 1)
    }

    func testHandDispatchStillRereadsTheLatestOwnVideoTile() throws {
        let lowered = "Myself video, Example, Video is off, Has context menu"
        let raised = "Myself video, Example, Video is off, Hand raised position 1, Has context menu"
        let tile = AXUIElementCreateApplication(30)
        var snapshot = mic(.unmuted)
        snapshot.handles[1]!.hands = [AXUIElementCreateApplication(11)]
        snapshot.handles[1]!.ownVideos = [tile]
        snapshot = TeamsSnapshot(windows: [WindowSnapshot(index: 1, controls: [
            ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise"),
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXImage", identifier: "", label: lowered)
        ])], complete: true, focusUnchanged: true, handles: snapshot.handles)
        var rerendered = snapshot
        rerendered.handles[1]!.ownVideos = [AXUIElementCreateApplication(31)]
        let client = FakeMediaAccessibility([snapshot, rerendered])
        client.identifier = "raisehands-button"
        client.ownVideo = rerendered.handles[1]!.ownVideos[0]
        client.ownVideoLabel = raised
        let backend = NativeMediaBackend<HandAssessment, HandState>(
            control: .hand, accessibility: client, checkFocus: { true },
            stateChangedReason: "hand_state_changed", classify: HandClassifier.assess) { assessment in
            guard assessment.state == .raised || assessment.state == .lowered,
                  assessment.windows.count == 1 else { return nil }
            return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
        }
        let first = try backend.sample()
        let sample = try backend.sample()
        XCTAssertEqual(first.targetID, sample.targetID)
        assertRejected("hand_state_changed") {
            try backend.press(targetID: sample.targetID!, expectedState: .lowered)
        }
        XCTAssertEqual(client.presses, 0)
        XCTAssertEqual(client.readCount, 2)
        XCTAssertTrue(client.readOwnVideo)
    }

    func testCameraDispatchUsesPreparedDiscoveryAndFreshCameraState() throws {
        for changed in [false, true] {
            var snapshot = mic(.unmuted)
            snapshot.handles[1]!.cameras = [AXUIElementCreateApplication(13)]
            snapshot = TeamsSnapshot(windows: [WindowSnapshot(index: 1, controls: snapshot.windows[0].controls + [
                ControlSnapshot(role: "AXButton", identifier: "video-button", label: "Turn camera on")
            ])], complete: true, focusUnchanged: true, handles: snapshot.handles)
            let client = FakeMediaAccessibility([snapshot])
            client.identifier = "video-button"
            client.label = changed ? "Turn camera off" : "Turn camera on"
            let backend = NativeMediaBackend<CameraAssessment, CameraState>(
                control: .camera, accessibility: client, checkFocus: { true },
                stateChangedReason: "camera_state_changed", classify: CameraClassifier.assess) { assessment in
                guard assessment.state == .on || assessment.state == .off,
                      assessment.windows.count == 1 else { return nil }
                return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
            }
            let sample = try backend.sample()
            if changed {
                assertRejected("camera_state_changed") {
                    try backend.press(targetID: sample.targetID!, expectedState: .off)
                }
            } else {
                try backend.press(targetID: sample.targetID!, expectedState: .off)
            }
            XCTAssertEqual(client.readCount, 1)
            XCTAssertEqual(client.presses, changed ? 0 : 1)
        }
    }

    private func native(_ client: FakeMediaAccessibility, focus: @escaping () -> Bool? = { true })
        -> NativeMediaBackend<MicrophoneAssessment, MicrophoneState> {
        NativeMediaBackend(control: .microphone, accessibility: client, checkFocus: focus,
                           stateChangedReason: "microphone_state_changed", classify: MicrophoneClassifier.assess) { assessment in
            guard assessment.state == .muted || assessment.state == .unmuted,
                  assessment.windows.count == 1 else { return nil }
            return MediaSelection(state: assessment.state, window: assessment.windows[0].window)
        }
    }

    private func adapter(_ client: FakeMediaAccessibility) -> NativeMicrophoneTestAdapter {
        NativeMicrophoneTestAdapter(native: native(client), client: client)
    }

    private func mic(_ state: MicrophoneState, index: Int = 1, window: pid_t = 10,
                     button: pid_t = 11, hangup: pid_t = 12, complete: Bool = true) -> TeamsSnapshot {
        let handles = CallWindowHandles(application: .current, window: AXUIElementCreateApplication(window),
                                        microphones: [AXUIElementCreateApplication(button)],
                                        hangups: [AXUIElementCreateApplication(hangup)])
        return TeamsSnapshot(windows: [WindowSnapshot(index: index, controls: [
            ControlSnapshot(role: "AXButton", identifier: "microphone-button",
                            label: state == .muted ? "Unmute mic" : "Mute mic"),
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
        ])], complete: complete, focusUnchanged: true, handles: [index: handles])
    }

    private func assertRejected(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? MediaPressRejected)?.reason, reason, file: file, line: line)
        }
    }
}

/// Handles are local identity tokens only; every operation that would access
/// another process is replaced here. No Teams UI or live media actions are used.
private final class FakeMediaAccessibility: MediaAccessibilityClient {
    let snapshots: [TeamsSnapshot]
    var uptime: TimeInterval = 0
    var readCount = 0
    var failRead = false
    var sameProcess = true
    var processGeneration: MediaProcessGeneration? = MediaProcessGeneration(pid: 123, launched: Date(timeIntervalSince1970: 1))
    var replaceProcessDuringValueRead = false
    var ready = true
    var role = "AXButton"
    var identifier = "microphone-button"
    var label = "Mute mic"
    var ownVideo: AXUIElement?
    var ownVideoLabel: String?
    var readOwnVideo = false
    var pressError = AXError.success
    var presses = 0
    var readCountAtPress = 0
    var waits = 0

    init(_ snapshots: [TeamsSnapshot]) { self.snapshots = snapshots }

    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        let index = readCount
        readCount += 1
        if failRead { throw TeamsReadError.accessibilityFailure(-25204) }
        return snapshots[min(index, snapshots.count - 1)]
    }

    func generation(of application: NSRunningApplication) -> MediaProcessGeneration? { processGeneration }
    func processMatches(pid: pid_t, launched: Date) -> Bool {
        sameProcess && processGeneration == MediaProcessGeneration(pid: pid, launched: launched)
    }
    func canPress(_ element: AXUIElement) -> Bool { ready }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        if replaceProcessDuringValueRead { sameProcess = false }
        if let ownVideo, CFEqual(element, ownVideo) {
            readOwnVideo = true
            return ["AXRole": "AXImage", "AXDescription": ownVideoLabel][name].flatMap { $0 as CFString? }
        }
        return ["AXRole": role, "AXDOMIdentifier": identifier, "AXDescription": label][name].map { $0 as CFString }
    }

    func press(_ element: AXUIElement) -> AXError {
        presses += 1
        readCountAtPress = readCount
        return pressError
    }
}

private struct NativeMicrophoneTestAdapter: MicrophoneBackend {
    let native: NativeMediaBackend<MicrophoneAssessment, MicrophoneState>
    let client: FakeMediaAccessibility

    func sample() throws -> MicrophoneObservation {
        let sample = try native.sample()
        return MicrophoneObservation(assessment: sample.assessment, targetID: sample.targetID, canPress: sample.canPress)
    }

    func press(targetID: String, expectedState: MicrophoneState) throws {
        try native.press(targetID: targetID, expectedState: expectedState)
    }

    func focusPreserved() -> Bool? { native.focusPreserved() }
    var verificationTimeRemaining: TimeInterval { native.verificationTimeRemaining }
    func waitForUpdate() {
        client.waits += 1
        client.uptime += min(0.05, verificationTimeRemaining)
    }
}
