import AppKit
import ApplicationServices

public enum TeamsCallCommands {
    /// Leaves the one non-held call. Teams may change focus when its call window closes.
    public static func end() throws -> CallEndResult {
        try end(environment: .live)
    }

    static func end<Focus: MediaCommandFocus>(environment: MediaActionEnvironment<Focus>) throws -> CallEndResult {
        try TeamsMediaCommandSupport.perform({ focus in
            let backend = AccessibilityCallEndBackend(accessibility: environment.makeAccessibility(),
                                                      checkFocus: focus.preserved, waitForUpdate: environment.waitForUpdate)
            return try CallEndController(backend: backend).end()
        }, environment: environment.lifecycle, onFinalization: { result, restored, focus in
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

    func owns(_ generation: MediaProcessGeneration?) -> Bool {
        generation?.pid == pid && generation?.launched == launched
    }

    func matches(_ handles: CallWindowHandles, generation: MediaProcessGeneration?) -> Bool {
        owns(generation) && CFEqual(window, handles.window) &&
            handles.hangups.count == 1 && CFEqual(button, handles.hangups[0])
    }
}

private enum CallEndAccessibilityError: Error {
    case timedOut
    case pressFailed(Int32)
}

final class AccessibilityCallEndBackend: CallEndBackend {
    private let accessibility: any MediaAccessibilityClient
    private let checkFocus: () -> Bool?
    private let wait: () -> Void
    private let deadline: TimeInterval
    private var target: CallEndTarget?

    init(accessibility: any MediaAccessibilityClient, checkFocus: @escaping () -> Bool?,
         waitForUpdate: @escaping () -> Void) {
        self.accessibility = accessibility
        self.checkFocus = checkFocus
        wait = waitForUpdate
        deadline = accessibility.uptime + 8
    }

    func sample() throws -> CallEndObservation {
        let snapshot = try read()
        let assessment = CallEndClassifier.assess(snapshot.windows, complete: snapshot.complete)
        guard assessment.state == .active, assessment.reason == nil, assessment.windows.count == 1,
              let handles = snapshot.handles[assessment.windows[0].window],
              handles.hangups.count == 1,
              let generation = accessibility.generation(of: handles.application) else {
            return CallEndObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        if target == nil {
            target = CallEndTarget(pid: generation.pid, launched: generation.launched,
                                   window: handles.window, button: handles.hangups[0])
        }
        guard let target, accessibility.processMatches(pid: target.pid, launched: target.launched),
              target.matches(handles, generation: generation) else {
            return CallEndObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        return CallEndObservation(assessment: assessment, targetID: target.id,
                                  canPress: accessibility.canPress(target.button))
    }

    func press(targetID: String) throws {
        let fresh: CallEndObservation
        do { fresh = try sample() }
        catch { throw CallEndPressRejected(reason: "preflight_failed") }
        if let reason = fresh.assessment.reason { throw CallEndPressRejected(reason: reason) }
        guard fresh.assessment.state == .active, fresh.targetID == targetID,
              let target, accessibility.processMatches(pid: target.pid, launched: target.launched) else {
            throw CallEndPressRejected(reason: "target_changed")
        }
        guard fresh.canPress else { throw CallEndPressRejected(reason: "control_unavailable") }

        let button = MediaButtonSnapshot.read(control: .call) { accessibility.value(target.button, $0) }
        guard CallEndClassifier.isLeaveButton(button) else {
            throw CallEndPressRejected(reason: "unrecognized_hangup_label")
        }
        guard accessibility.processMatches(pid: target.pid, launched: target.launched) else {
            throw CallEndPressRejected(reason: "target_changed")
        }
        guard accessibility.canPress(target.button) else { throw CallEndPressRejected(reason: "control_unavailable") }
        // Observe focus for reporting, but allow the change requested for call end.
        _ = checkFocus()
        guard accessibility.uptime < deadline else {
            throw CallEndPressRejected(reason: "preflight_failed")
        }
        let error = accessibility.press(target.button)
        guard error == .success else { throw CallEndAccessibilityError.pressFailed(error.rawValue) }
    }

    func verify(targetID: String) throws -> CallEndVerification {
        let snapshot = try read()
        let assessment = CallEndClassifier.assess(snapshot.windows, complete: snapshot.complete)
        guard let target, target.id == targetID,
              accessibility.processMatches(pid: target.pid, launched: target.launched) else {
            return CallEndVerification(assessment: assessment, presence: .changed)
        }
        guard snapshot.complete else { return CallEndVerification(assessment: assessment, presence: .unconfirmed) }
        let windows = snapshot.handles.values.filter { target.owns(accessibility.generation(of: $0.application)) }
        if let original = windows.first(where: { CFEqual($0.window, target.window) }) {
            let presence: CallEndPresence
            if original.hangups.isEmpty {
                presence = .unconfirmed
            } else {
                presence = target.matches(original, generation: accessibility.generation(of: original.application)) ?
                    .sameCall : .changed
            }
            return CallEndVerification(assessment: assessment, presence: presence)
        }
        // An empty AXWindows response can be a discovery failure. Require another
        // inspectable window in the same process and no remaining non-held call.
        guard !windows.isEmpty else { return CallEndVerification(assessment: assessment, presence: .unconfirmed) }
        let presence: CallEndPresence = assessment.windows.isEmpty ? .windowClosed : .changed
        return CallEndVerification(assessment: assessment, presence: presence)
    }

    func focusPreserved() -> Bool? { checkFocus() }
    func waitForUpdate() { wait() }

    private func read() throws -> TeamsSnapshot {
        let remaining = deadline - accessibility.uptime
        guard remaining > 0 else { throw CallEndAccessibilityError.timedOut }
        return try accessibility.read(control: .call, timeout: min(1.5, remaining))
    }
}
