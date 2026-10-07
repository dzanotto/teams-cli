import AppKit
import ApplicationServices

/// Observes focus without activating applications, raising windows, or restoring focus.
/// Create, poll, and stop this monitor on the same thread, pumping that thread's run loop
/// while waiting. Notifications are best effort; an unchanged result is not a guarantee
/// that macOS or an application reported every brief focus change.
final class FocusMonitor {
    private let state: FocusMonitorState
    private let environment: FocusMonitoringEnvironment
    private var activationObserver: FocusObservation?
    private var windowObserver: FocusObservation?
    private var stopped = false

    convenience init() {
        self.init(environment: .live)
    }

    init(environment: FocusMonitoringEnvironment) {
        self.environment = environment
        state = FocusMonitorState(baseline: environment.capture())

        let state = self.state
        activationObserver = environment.observeActivation { [weak state] pid in
            state?.observeActivation(pid: pid)
        }

        if let pid = state.baseline.pid, state.baseline.window != nil {
            windowObserver = environment.observeWindow(pid) { [weak state] element in
                guard let state else { return }
                state.observeWindowNotification(element, role: environment.role(element))
                state.observeCurrent(environment.capture())
            }
            if windowObserver == nil { state.markInconclusive() }
        } else {
            state.markInconclusive()
        }

        // Close the interval between the initial snapshot and notification registration.
        state.observeCurrent(environment.capture())
    }

    func preserved() -> Bool? {
        guard !stopped else { return nil }
        // Drain notifications already queued during synchronous accessibility work. This
        // also catches an app/window switch followed by a return to the original focus.
        environment.drainNotifications()
        state.observeCurrent(environment.capture())
        return state.result()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        activationObserver?.cancel()
        activationObserver = nil
        windowObserver?.cancel()
        windowObserver = nil
    }

    deinit { stop() }
}

struct MonitoredFocus {
    let pid: pid_t?
    let window: AXUIElement?

    static func capture() -> MonitoredFocus {
        capture(frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                focusedWindow: readFocusedWindow)
    }

    static func capture(frontmostPID: () -> pid_t?, focusedWindow: (pid_t) -> AXUIElement?) -> MonitoredFocus {
        guard let pid = frontmostPID() else {
            return MonitoredFocus(pid: nil, window: nil)
        }
        let window = focusedWindow(pid)
        let afterPID = frontmostPID()
        guard afterPID == pid else {
            return MonitoredFocus(pid: afterPID, window: nil)
        }
        return MonitoredFocus(pid: pid, window: window)
    }

    private static func readFocusedWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var rawWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow)
        guard error == .success, let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            return nil
        }
        return (rawWindow as! AXUIElement)
    }
}

/// NotificationCenter may invoke its handler off the creating thread. Only the two
/// latched flags are mutable, and every access to them is protected by this lock.
private final class FocusMonitorState: @unchecked Sendable {
    let baseline: MonitoredFocus
    private let lock = NSLock()
    private var changed = false
    private var inconclusive = false

    init(baseline: MonitoredFocus) {
        self.baseline = baseline
        inconclusive = baseline.pid == nil || baseline.window == nil
    }

    func observeActivation(pid: pid_t?) {
        guard let pid, let baselinePID = baseline.pid else {
            markInconclusive()
            return
        }
        if pid != baselinePID { markChanged() }
    }

    func observeWindowNotification(_ element: AXUIElement, role: String?) {
        // Some applications send the new window; others send the application object.
        // A different window in the event must remain recorded even if focus returned
        // before the callback was delivered.
        if role == kAXWindowRole, let baselineWindow = baseline.window {
            if !CFEqual(baselineWindow, element) { markChanged() }
        } else {
            // The notification itself says the focused window changed. An application
            // object cannot establish which window was focused at the event's time.
            markChanged()
        }
    }

    func observeCurrent(_ current: MonitoredFocus) {
        guard let baselinePID = baseline.pid, let currentPID = current.pid else {
            markInconclusive()
            return
        }
        guard baselinePID == currentPID else {
            markChanged()
            return
        }
        guard let baselineWindow = baseline.window, let currentWindow = current.window else {
            markInconclusive()
            return
        }
        if !CFEqual(baselineWindow, currentWindow) { markChanged() }
    }

    func markInconclusive() {
        lock.lock()
        inconclusive = true
        lock.unlock()
    }

    private func markChanged() {
        lock.lock()
        changed = true
        lock.unlock()
    }

    func result() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        if changed { return false }
        if inconclusive { return nil }
        return true
    }
}
