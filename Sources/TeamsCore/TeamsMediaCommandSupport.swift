import AppKit
import ApplicationServices

protocol MediaCommandFocus {
    func preserved() -> Bool?
    func stop()
}

extension FocusMonitor: MediaCommandFocus {}

/// Keeps lifecycle tests independent of the desktop while exercising the real lock and cleanup.
struct MediaCommandEnvironment<Focus: MediaCommandFocus> {
    let isTrusted: () -> Bool
    let acquireLock: () throws -> MediaCommandLock
    let makeFocus: () -> Focus
    let makeExposure: () throws -> TeamsAccessibilityExposure
}

extension MediaCommandEnvironment where Focus == FocusMonitor {
    static var live: Self {
        Self(isTrusted: { AXIsProcessTrusted() }, acquireLock: { try MediaCommandLock() },
             makeFocus: { FocusMonitor() }, makeExposure: { try TeamsAccessibilityExposure() })
    }
}

/// Shared lifecycle: lock, observe focus, expose AX, act, restore, finalize.
enum TeamsMediaCommandSupport {
    static func perform<Result>(
        _ operation: (FocusMonitor) throws -> Result,
        onFinalizationFailure: (Result, String, Bool?) -> Result
    ) throws -> Result {
        try perform(operation, environment: .live, onFinalizationFailure: onFinalizationFailure)
    }

    static func perform<Result, Focus: MediaCommandFocus>(
        _ operation: (Focus) throws -> Result,
        environment: MediaCommandEnvironment<Focus>,
        timings: CommandTimings? = nil,
        onFinalizationFailure: (Result, String, Bool?) -> Result
    ) throws -> Result {
        try perform(operation, environment: environment, timings: timings, onFinalization: { result, restored, focus in
            guard restored, focus == true else {
                let focusReason = focus == nil ? "focus_unavailable" : "focus_changed"
                let reason = !restored ? "accessibility_cleanup_failed" : focusReason
                return onFinalizationFailure(result, reason, focus)
            }
            return result
        })
    }

    /// Call end permits Teams to change focus, but still observes and reports it.
    static func perform<Result>(
        _ operation: (FocusMonitor) throws -> Result,
        onFinalization: (Result, Bool, Bool?) -> Result
    ) throws -> Result {
        try perform(operation, environment: .live, onFinalization: onFinalization)
    }

    static func perform<Result, Focus: MediaCommandFocus>(
        _ operation: (Focus) throws -> Result,
        environment: MediaCommandEnvironment<Focus>,
        timings: CommandTimings? = nil,
        onFinalization: (Result, Bool, Bool?) -> Result
    ) throws -> Result {
        guard environment.isTrusted() else { throw TeamsReadError.accessibilityDenied }
        let commandLock = try timings.measure("lock_acquire", environment.acquireLock)
        defer { timings.measure("lock_release", commandLock.release) }
        let focus = timings.measure("focus_start", environment.makeFocus)
        defer { timings.measure("focus_stop", focus.stop) }
        let exposure: TeamsAccessibilityExposure
        do {
            exposure = try timings.measure("accessibility_setup", environment.makeExposure)
        } catch {
            // Initialization finalizes any setup cleanup before throwing. Drain focus
            // observations while monitoring is still alive; no cleanup writes follow.
            _ = timings.measure("focus_check", focus.preserved)
            throw error
        }
        // restore() caches both success and failure. Explicit finalization below
        // prevents deferred/deinit writes after the final focus observation.
        defer { _ = exposure.restore() }
        let result: Result
        do {
            result = try operation(focus)
        } catch {
            let restored = timings.measure("accessibility_cleanup", exposure.restore)
            _ = timings.measure("focus_check", focus.preserved)
            guard restored else { throw MicrophoneCommandError.accessibilityCleanupFailed }
            throw error
        }
        let restored = timings.measure("accessibility_cleanup", exposure.restore)
        let finalFocus = timings.measure("focus_check", focus.preserved)
        return onFinalization(result, restored, finalFocus)
    }
}

struct MediaSelection<State> {
    let state: State
    let window: Int
}

struct NativeMediaObservation<Assessment> {
    let assessment: Assessment
    let targetID: String?
    let canPress: Bool
}

private struct MediaTargetHandle {
    let id: String
    let pid: pid_t
    let launched: Date
    let window: AXUIElement
    let button: AXUIElement
    let hangup: AXUIElement
    var ownVideo: AXUIElement?

    func matches(_ handles: CallWindowHandles, generation: MediaProcessGeneration, control: MediaControl) -> Bool {
        let buttons = handles.buttons(for: control)
        return generation.pid == pid && generation.launched == launched &&
            buttons.count == 1 && handles.hangups.count == 1 &&
            CFEqual(window, handles.window) && CFEqual(button, buttons[0]) &&
            CFEqual(hangup, handles.hangups[0])
    }
}

private enum AccessibilityActionError: Error {
    case timedOut
    case pressFailed(Int32)
}

/// Reads the live button identity and label again just before dispatch.
enum MediaButtonSnapshot {
    static func read(control: MediaControl, value: (String) -> Any?) -> ControlSnapshot {
        let identifiers = ["AXDOMIdentifier", kAXIdentifierAttribute].compactMap { value($0) as? String }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { value($0) as? String }
        return ControlSnapshot(role: value(kAXRoleAttribute) as? String ?? "",
                               identifier: identifiers.contains(control.rawValue) ? control.rawValue : "",
                               label: labels.first(where: { !$0.isEmpty }) ?? "")
    }
}

/// AX mechanics shared by microphone, camera and hand; each supplies its own classifier.
final class NativeMediaBackend<Assessment, State: Equatable> {
    private let accessibility: any MediaAccessibilityClient
    private let control: MediaControl
    private let checkFocus: () -> Bool?
    private let classify: ([WindowSnapshot], Bool) -> Assessment
    private let select: (Assessment) -> MediaSelection<State>?
    private let stateChangedReason: String
    private let timings: CommandTimings?
    private let deadline: TimeInterval
    private var target: MediaTargetHandle?
    /// Only the latest successful sample can authorize one dispatch attempt.
    /// Every new sample invalidates it before reading, including failed reads.
    private var preflight: NativeMediaObservation<Assessment>?

    init(control: MediaControl, accessibility: any MediaAccessibilityClient,
         checkFocus: @escaping () -> Bool?, stateChangedReason: String,
         classify: @escaping ([WindowSnapshot], Bool) -> Assessment,
         timings: CommandTimings? = nil,
         select: @escaping (Assessment) -> MediaSelection<State>?) {
        self.timings = timings
        self.accessibility = accessibility
        self.control = control
        self.checkFocus = checkFocus
        self.classify = classify
        self.select = select
        self.stateChangedReason = stateChangedReason
        deadline = accessibility.uptime + 8
    }

    var verificationTimeRemaining: TimeInterval { max(0, deadline - accessibility.uptime) }

    func sample() throws -> NativeMediaObservation<Assessment> {
        preflight = nil
        let remaining = deadline - accessibility.uptime
        guard remaining > 0 else { throw AccessibilityActionError.timedOut }
        let snapshot = try timings.measure("accessibility_read") {
            let snapshot = try accessibility.read(control: control, timeout: min(1.5, remaining))
            timings?.detail("complete", String(snapshot.complete))
            return snapshot
        }
        let assessment = classify(snapshot.windows, snapshot.complete)
        guard let selected = select(assessment),
              let handles = snapshot.handles[selected.window],
              handles.buttons(for: control).count == 1, handles.hangups.count == 1,
              control != .hand || handles.ownVideos.count == 1,
              let generation = accessibility.generation(of: handles.application) else {
            return NativeMediaObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        let button = handles.buttons(for: control)[0]
        if target?.matches(handles, generation: generation, control: control) != true {
            target = MediaTargetHandle(id: UUID().uuidString, pid: generation.pid,
                                       launched: generation.launched, window: handles.window,
                                       button: button, hangup: handles.hangups[0])
        }
        // Self-video tiles can rerender independently of the call/control identity.
        // Retain the current scan's handle for a fresh state read immediately before pressing.
        target?.ownVideo = control == .hand ? handles.ownVideos.first : nil
        // A temporarily disabled camera retains its identity while Teams starts it.
        let observation = NativeMediaObservation(assessment: assessment, targetID: target?.id,
                                                 canPress: accessibility.canPress(button))
        preflight = observation
        return observation
    }

    func press(targetID: String, expectedState: State) throws {
        let button = try timings.measure("dispatch_validation") {
            // The controller has just rescanned eligibility, hold exclusions and identity.
            // Consume that evidence once instead of repeating the full tree traversal.
            // Direct state, process, readiness and focus checks below remain fresh.
            let prepared = preflight
            preflight = nil
            guard let fresh = prepared else { throw MediaPressRejected(reason: "preflight_failed") }
            guard fresh.targetID == targetID, let target,
                  accessibility.processMatches(pid: target.pid, launched: target.launched) else {
                throw MediaPressRejected(reason: "target_changed")
            }
            guard select(fresh.assessment)?.state == expectedState else {
                throw MediaPressRejected(reason: stateChangedReason)
            }
            guard fresh.canPress else { throw MediaPressRejected(reason: "control_unavailable") }

            let button = MediaButtonSnapshot.read(control: control) { accessibility.value(target.button, $0) }
            // The consumed full scan established call eligibility. This synthetic hangup
            // permits the classifier to validate the freshly read button and state indicator.
            var controls = [
                button, ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "")
            ]
            if control == .hand, let ownVideo = target.ownVideo {
                controls.append(OwnVideoHandIndicator.read { accessibility.value(ownVideo, $0) })
            }
            let check = classify([WindowSnapshot(index: 1, controls: controls)], true)
            guard select(check)?.state == expectedState else {
                throw MediaPressRejected(reason: stateChangedReason)
            }
            guard accessibility.processMatches(pid: target.pid, launched: target.launched) else {
                throw MediaPressRejected(reason: "target_changed")
            }
            guard accessibility.canPress(target.button) else { throw MediaPressRejected(reason: "control_unavailable") }
            guard let preserved = timings.measure("focus_check", checkFocus) else {
                throw MediaPressRejected(reason: "focus_unavailable")
            }
            guard preserved else { throw MediaPressRejected(reason: "focus_changed") }
            guard accessibility.uptime < deadline else {
                throw MediaPressRejected(reason: "preflight_failed")
            }
            return target.button
        }
        let error = timings.measure("ax_press") { accessibility.press(button) }
        guard error == .success else { throw AccessibilityActionError.pressFailed(error.rawValue) }
    }

    func focusPreserved() -> Bool? { checkFocus() }
}
