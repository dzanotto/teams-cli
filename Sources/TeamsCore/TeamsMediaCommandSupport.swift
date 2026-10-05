import AppKit
import ApplicationServices
import Darwin

/// Shared lifecycle: lock, observe focus, expose AX, act, restore, finalize.
enum TeamsMediaCommandSupport {
    static func perform<Result>(
        _ operation: (FocusMonitor) throws -> Result,
        onFinalizationFailure: (Result, String, Bool?) -> Result
    ) throws -> Result {
        try perform(operation, onFinalization: { result, restored, focus in
            guard restored, focus == true else {
                let reason = !restored ? "accessibility_cleanup_failed" :
                    (focus == nil ? "focus_unavailable" : "focus_changed")
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
        guard AXIsProcessTrusted() else { throw TeamsReadError.accessibilityDenied }
        let commandLock = try MediaCommandLock()
        defer { commandLock.release() }
        let focus = FocusMonitor()
        defer { focus.stop() }
        let exposure: TeamsAccessibilityExposure
        do {
            exposure = try TeamsAccessibilityExposure()
        } catch {
            // Initialization finalizes any setup cleanup before throwing. Drain focus
            // observations while monitoring is still alive; no cleanup writes follow.
            _ = focus.preserved()
            throw error
        }
        // restore() caches both success and failure. Explicit finalization below
        // prevents deferred/deinit writes after the final focus observation.
        defer { _ = exposure.restore() }
        let result: Result
        do {
            result = try operation(focus)
        } catch {
            let restored = exposure.restore()
            _ = focus.preserved()
            guard restored else { throw MicrophoneCommandError.accessibilityCleanupFailed }
            throw error
        }
        let restored = exposure.restore()
        let finalFocus = focus.preserved()
        return onFinalization(result, restored, finalFocus)
    }
}

private final class MediaCommandLock {
    private var descriptor: Int32

    init() throws {
        // Retain the original microphone lock path so camera/call commands also serialize
        // with older microphone binaries. Keep the inode when releasing the lock.
        let path = "/tmp/teams-cli-microphone-\(getuid()).lock"
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw MicrophoneCommandError.lockUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o077) == 0 else {
            close(descriptor)
            descriptor = -1
            throw MicrophoneCommandError.lockUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            descriptor = -1
            throw busy ? MicrophoneCommandError.commandInProgress : .lockUnavailable
        }
    }

    func release() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
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

    func matches(_ handles: CallWindowHandles, control: MediaControl) -> Bool {
        let buttons = handles.buttons(for: control)
        return handles.application.processIdentifier == pid && handles.application.launchDate == launched &&
            buttons.count == 1 && handles.hangups.count == 1 &&
            CFEqual(window, handles.window) && CFEqual(button, buttons[0]) &&
            CFEqual(hangup, handles.hangups[0])
    }

    var processStillRunning: Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated && application.launchDate == launched
    }
}

private enum AccessibilityActionError: Error {
    case timedOut
    case pressFailed(Int32)
}

/// AX mechanics shared by microphone and camera; each supplies its own classifier.
final class NativeMediaBackend<Assessment, State: Equatable> {
    private let reader = TeamsAccessibilityReader()
    private let control: MediaControl
    private let focus: FocusMonitor
    private let classify: ([WindowSnapshot], Bool) -> Assessment
    private let select: (Assessment) -> MediaSelection<State>?
    private let stateChangedReason: String
    private let deadline: TimeInterval
    private var target: MediaTargetHandle?

    init(control: MediaControl, focus: FocusMonitor,
         stateChangedReason: String,
         classify: @escaping ([WindowSnapshot], Bool) -> Assessment,
         select: @escaping (Assessment) -> MediaSelection<State>?) {
        self.control = control
        self.focus = focus
        self.classify = classify
        self.select = select
        self.stateChangedReason = stateChangedReason
        deadline = ProcessInfo.processInfo.systemUptime + 8
    }

    func sample() throws -> NativeMediaObservation<Assessment> {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AccessibilityActionError.timedOut }
        let snapshot = try reader.read(control: control, timeout: min(1.5, remaining))
        let assessment = classify(snapshot.windows, snapshot.complete)
        guard let selected = select(assessment),
              let handles = snapshot.handles[selected.window],
              handles.buttons(for: control).count == 1, handles.hangups.count == 1,
              let launched = handles.application.launchDate else {
            return NativeMediaObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        let button = handles.buttons(for: control)[0]
        if target?.matches(handles, control: control) != true {
            target = MediaTargetHandle(id: UUID().uuidString, pid: handles.application.processIdentifier,
                                       launched: launched, window: handles.window,
                                       button: button, hangup: handles.hangups[0])
        }
        // A temporarily disabled camera retains its identity while Teams starts it.
        return NativeMediaObservation(assessment: assessment, targetID: target?.id, canPress: canPress(button))
    }

    func press(targetID: String, expectedState: State) throws {
        // Refresh selection, hold exclusions and identity immediately before dispatch.
        let fresh: NativeMediaObservation<Assessment>
        do { fresh = try sample() }
        catch { throw MediaPressRejected(reason: "preflight_failed") }
        guard fresh.targetID == targetID, let target, target.processStillRunning else {
            throw MediaPressRejected(reason: "target_changed")
        }
        guard select(fresh.assessment)?.state == expectedState else {
            throw MediaPressRejected(reason: stateChangedReason)
        }
        guard fresh.canPress else { throw MediaPressRejected(reason: "control_unavailable") }

        let identifiers = ["AXDOMIdentifier", kAXIdentifierAttribute].compactMap {
            value(target.button, $0) as? String
        }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap {
            value(target.button, $0) as? String
        }
        let button = ControlSnapshot(
            role: value(target.button, kAXRoleAttribute) as? String ?? "",
            identifier: identifiers.contains(control.rawValue) ? control.rawValue : "",
            label: labels.first(where: { !$0.isEmpty }) ?? ""
        )
        // The full scan above established call eligibility. This synthetic hangup
        // permits the media classifier to validate only the freshly read live button.
        let check = classify([WindowSnapshot(index: 1, controls: [
            button, ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "")
        ])], true)
        guard select(check)?.state == expectedState else {
            throw MediaPressRejected(reason: stateChangedReason)
        }
        guard target.processStillRunning else { throw MediaPressRejected(reason: "target_changed") }
        guard canPress(target.button) else { throw MediaPressRejected(reason: "control_unavailable") }
        guard let preserved = focus.preserved() else { throw MediaPressRejected(reason: "focus_unavailable") }
        guard preserved else { throw MediaPressRejected(reason: "focus_changed") }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw MediaPressRejected(reason: "preflight_failed")
        }
        let error = AXUIElementPerformAction(target.button, kAXPressAction as CFString)
        guard error == .success else { throw AccessibilityActionError.pressFailed(error.rawValue) }
    }

    func focusPreserved() -> Bool? { focus.preserved() }

    func waitForUpdate() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private func canPress(_ element: AXUIElement) -> Bool {
        guard value(element, kAXEnabledAttribute) as? Bool == true else { return false }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success &&
            (actions as? [String] ?? []).contains(kAXPressAction)
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
