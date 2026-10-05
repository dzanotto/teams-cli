import AppKit
import ApplicationServices
import Darwin

public enum MicrophoneCommandError: Error {
    case commandInProgress
    case lockUnavailable
    case accessibilitySetupUnavailable
    case accessibilityCleanupFailed
}

/// Serializes cooperating CLI commands and changes only the selected microphone button.
public enum TeamsMicrophoneCommands {
    public static func set(_ target: MicrophoneTarget) throws -> MicrophoneActionResult {
        guard AXIsProcessTrusted() else { throw TeamsReadError.accessibilityDenied }
        let commandLock = try MicrophoneCommandLock()
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
        // Emergency fallback only: restore() caches both success and failure, so
        // explicit finalization below prevents later deferred/deinit writes.
        defer { _ = exposure.restore() }
        let backend = AccessibilityMicrophoneBackend(focus: focus)
        let result: MicrophoneActionResult
        do {
            result = try MicrophoneController(backend: backend).set(target)
        } catch {
            let restored = exposure.restore()
            _ = focus.preserved()
            guard restored else { throw MicrophoneCommandError.accessibilityCleanupFailed }
            throw error
        }
        let restored = exposure.restore()
        let finalFocus = focus.preserved()
        guard restored, finalFocus == true else {
            let reason = !restored ? "accessibility_cleanup_failed" :
                (finalFocus == nil ? "focus_unavailable" : "focus_changed")
            return MicrophoneActionResult(state: .unknown, reason: reason,
                                          changed: result.actionAttempted ? nil : false,
                                          actionAttempted: result.actionAttempted, focusUnchanged: finalFocus,
                                          windows: result.windows, excludedWindows: result.excludedWindows,
                                          success: false)
        }
        return result
    }
}

private final class MicrophoneCommandLock {
    private var descriptor: Int32

    init() throws {
        // Keep the inode in place when releasing: deleting a lock file can let
        // concurrent processes lock different inodes for the same pathname.
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

private struct TargetHandle {
    let id: String
    let pid: pid_t
    let launched: Date
    let window: AXUIElement
    let microphone: AXUIElement
    let hangup: AXUIElement

    func matches(_ handles: CallWindowHandles) -> Bool {
        handles.application.processIdentifier == pid && handles.application.launchDate == launched &&
        handles.microphones.count == 1 && handles.hangups.count == 1 &&
        CFEqual(window, handles.window) && CFEqual(microphone, handles.microphones[0]) &&
        CFEqual(hangup, handles.hangups[0])
    }
}

private enum AccessibilityActionError: Error {
    case timedOut
    case pressFailed(Int32)
}

private final class AccessibilityMicrophoneBackend: MicrophoneBackend {
    private let reader = TeamsAccessibilityReader()
    private let focus: FocusMonitor
    private var target: TargetHandle?
    private let deadline = ProcessInfo.processInfo.systemUptime + 8

    init(focus: FocusMonitor) { self.focus = focus }

    func sample() throws -> MicrophoneObservation {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw AccessibilityActionError.timedOut }
        let snapshot = try reader.read(timeout: min(1.5, remaining))
        let assessment = MicrophoneClassifier.assess(snapshot.windows, complete: snapshot.complete)
        guard assessment.state == .muted || assessment.state == .unmuted,
              assessment.windows.count == 1,
              let handles = snapshot.handles[assessment.windows[0].window],
              handles.microphones.count == 1, handles.hangups.count == 1,
              let launched = handles.application.launchDate else {
            return MicrophoneObservation(assessment: assessment, targetID: nil, canPress: false)
        }
        if target?.matches(handles) != true {
            target = TargetHandle(id: UUID().uuidString, pid: handles.application.processIdentifier,
                                  launched: launched, window: handles.window,
                                  microphone: handles.microphones[0], hangup: handles.hangups[0])
        }
        let microphone = handles.microphones[0]
        let enabled = value(microphone, kAXEnabledAttribute) as? Bool == true
        var actions: CFArray?
        let actionError = AXUIElementCopyActionNames(microphone, &actions)
        let supportsPress = actionError == .success && (actions as? [String] ?? []).contains(kAXPressAction)
        return MicrophoneObservation(assessment: assessment, targetID: target?.id,
                                     canPress: enabled && supportsPress)
    }

    func press(targetID: String, expectedState: MicrophoneState) throws {
        // Resolve again immediately before dispatch. The controller's token is tied
        // to AX objects and process generation, never to a changing window index.
        let fresh: MicrophoneObservation
        do { fresh = try sample() }
        catch { throw MicrophonePressRejected(reason: "preflight_failed") }
        guard fresh.targetID == targetID, let target,
              let app = NSRunningApplication(processIdentifier: target.pid),
              !app.isTerminated, app.launchDate == target.launched else {
            throw MicrophonePressRejected(reason: "target_changed")
        }
        guard fresh.assessment.state == expectedState else {
            throw MicrophonePressRejected(reason: "microphone_state_changed")
        }
        guard fresh.canPress else { throw MicrophonePressRejected(reason: "control_unavailable") }

        // Verify the exact live button one last time: AXPress is a toggle, not an
        // atomic desired-state API. Refuse changed state instead of toggling blindly.
        let identifiers = ["AXDOMIdentifier", kAXIdentifierAttribute].compactMap {
            value(target.microphone, $0) as? String
        }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap {
            value(target.microphone, $0) as? String
        }
        let label = labels.first(where: { !$0.isEmpty }) ?? ""
        let check = MicrophoneClassifier.assess([WindowSnapshot(index: 1, controls: [
            ControlSnapshot(role: value(target.microphone, kAXRoleAttribute) as? String ?? "",
                            identifier: identifiers.contains("microphone-button") ? "microphone-button" : "",
                            label: label),
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "")
        ])], complete: true)
        guard check.state == expectedState else {
            throw MicrophonePressRejected(reason: "microphone_state_changed")
        }
        guard value(target.microphone, kAXEnabledAttribute) as? Bool == true else {
            throw MicrophonePressRejected(reason: "control_unavailable")
        }
        guard let preserved = focus.preserved() else { throw MicrophonePressRejected(reason: "focus_unavailable") }
        guard preserved else { throw MicrophonePressRejected(reason: "focus_changed") }
        let error = AXUIElementPerformAction(target.microphone, kAXPressAction as CFString)
        guard error == .success else { throw AccessibilityActionError.pressFailed(error.rawValue) }
    }

    func focusPreserved() -> Bool? { focus.preserved() }

    func waitForUpdate() {
        // Pump focus/activation notifications while allowing Teams to update its UI.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
}
