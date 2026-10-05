import AppKit
import ApplicationServices

public enum TeamsCallCommands {
    /// Leaves the one non-held call. Teams may change focus when its call window closes.
    public static func end() throws -> CallEndResult {
        try TeamsMediaCommandSupport.perform({ focus in
            try CallEndController(backend: AccessibilityCallEndBackend(focus: focus)).end()
        }, onFinalization: { result, restored, focus in
            result.finalized(restored: restored, focus: focus)
        })
    }
}

private struct CallEndTarget {
    let id = UUID().uuidString
    let pid: pid_t
    let launched: Date
    let window: AXUIElement
    let button: AXUIElement

    func owns(_ handles: CallWindowHandles) -> Bool {
        handles.application.processIdentifier == pid && handles.application.launchDate == launched
    }

    func matches(_ handles: CallWindowHandles) -> Bool {
        owns(handles) && CFEqual(window, handles.window) &&
            handles.hangups.count == 1 && CFEqual(button, handles.hangups[0])
    }

    var processStillRunning: Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated && application.launchDate == launched
    }
}

private enum CallEndAccessibilityError: Error {
    case timedOut
    case pressFailed(Int32)
}

private final class AccessibilityCallEndBackend: CallEndBackend {
    private let reader = TeamsAccessibilityReader()
    private let focus: FocusMonitor
    private let deadline = ProcessInfo.processInfo.systemUptime + 8
    private var target: CallEndTarget?

    init(focus: FocusMonitor) { self.focus = focus }

    func sample() throws -> CallEndObservation {
        let snapshot = try read()
        let assessment = CallEndClassifier.assess(snapshot.windows, complete: snapshot.complete)
        guard assessment.state == .active, assessment.reason == nil, assessment.windows.count == 1,
              let handles = snapshot.handles[assessment.windows[0].window],
              handles.hangups.count == 1, let launched = handles.application.launchDate else {
            return CallEndObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        if target == nil {
            target = CallEndTarget(pid: handles.application.processIdentifier, launched: launched,
                                   window: handles.window, button: handles.hangups[0])
        }
        guard let target, target.processStillRunning, target.matches(handles) else {
            return CallEndObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        return CallEndObservation(assessment: assessment, targetID: target.id, canPress: canPress(target.button))
    }

    func press(targetID: String) throws {
        let fresh: CallEndObservation
        do { fresh = try sample() }
        catch { throw CallEndPressRejected(reason: "preflight_failed") }
        if let reason = fresh.assessment.reason { throw CallEndPressRejected(reason: reason) }
        guard fresh.assessment.state == .active, fresh.targetID == targetID,
              let target, target.processStillRunning else {
            throw CallEndPressRejected(reason: "target_changed")
        }
        guard fresh.canPress else { throw CallEndPressRejected(reason: "control_unavailable") }

        let identifiers = ["AXDOMIdentifier", kAXIdentifierAttribute].compactMap { value(target.button, $0) as? String }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { value(target.button, $0) as? String }
        let button = ControlSnapshot(role: value(target.button, kAXRoleAttribute) as? String ?? "",
                                     identifier: identifiers.contains("hangup-button") ? "hangup-button" : "",
                                     label: labels.first(where: { !$0.isEmpty }) ?? "")
        guard CallEndClassifier.isLeaveButton(button) else {
            throw CallEndPressRejected(reason: "unrecognized_hangup_label")
        }
        guard target.processStillRunning else { throw CallEndPressRejected(reason: "target_changed") }
        guard canPress(target.button) else { throw CallEndPressRejected(reason: "control_unavailable") }
        // Observe focus for reporting, but allow the change requested for call end.
        _ = focus.preserved()
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw CallEndPressRejected(reason: "preflight_failed")
        }
        let error = AXUIElementPerformAction(target.button, kAXPressAction as CFString)
        guard error == .success else { throw CallEndAccessibilityError.pressFailed(error.rawValue) }
    }

    func verify(targetID: String) throws -> CallEndVerification {
        let snapshot = try read()
        let assessment = CallEndClassifier.assess(snapshot.windows, complete: snapshot.complete)
        guard let target, target.id == targetID, target.processStillRunning else {
            return CallEndVerification(assessment: assessment, presence: .changed)
        }
        guard snapshot.complete else { return CallEndVerification(assessment: assessment, presence: .unconfirmed) }
        let windows = snapshot.handles.values.filter { target.owns($0) }
        if let original = windows.first(where: { CFEqual($0.window, target.window) }) {
            let presence: CallEndPresence
            if original.hangups.isEmpty {
                presence = .unconfirmed
            } else {
                presence = target.matches(original) ? .sameCall : .changed
            }
            return CallEndVerification(assessment: assessment, presence: presence)
        }
        // An empty AXWindows response can be a discovery failure. Require another
        // inspectable window in the same process and no remaining non-held call.
        guard !windows.isEmpty else { return CallEndVerification(assessment: assessment, presence: .unconfirmed) }
        let presence: CallEndPresence = assessment.windows.isEmpty ? .windowClosed : .changed
        return CallEndVerification(assessment: assessment, presence: presence)
    }

    func focusPreserved() -> Bool? { focus.preserved() }
    func waitForUpdate() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    private func read() throws -> TeamsSnapshot {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw CallEndAccessibilityError.timedOut }
        return try reader.read(control: .call, timeout: min(1.5, remaining))
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
