import AppKit
import ApplicationServices

/// Observes focus without activating applications, raising windows, or restoring focus.
/// Create, poll, and stop this monitor on the same thread, pumping that thread's run loop
/// while waiting. Notifications are best effort; an unchanged result is not a guarantee
/// that macOS or an application reported every brief focus change.
final class FocusMonitor {
    private let state: FocusMonitorState
    private let runLoop: CFRunLoop
    private let notificationCenter: NotificationCenter
    private var activationObserver: NSObjectProtocol?
    private var windowObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var stopped = false

    init() {
        state = FocusMonitorState(baseline: MonitoredFocus.capture())
        runLoop = CFRunLoopGetCurrent()
        notificationCenter = NSWorkspace.shared.notificationCenter

        let state = self.state
        activationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak state] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            state?.observeActivation(pid: application?.processIdentifier)
        }

        if let pid = state.baseline.pid, state.baseline.window != nil {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            var observer: AXObserver?
            let created = AXObserverCreate(pid, { _, element, _, context in
                guard let context else { return }
                let state = Unmanaged<FocusMonitorState>.fromOpaque(context).takeUnretainedValue()
                state.observeWindowNotification(element)
            }, &observer)

            if created == .success, let observer {
                let registered = AXObserverAddNotification(
                    observer,
                    application,
                    kAXFocusedWindowChangedNotification as CFString,
                    Unmanaged.passUnretained(state).toOpaque()
                )
                if registered == .success {
                    windowObserver = observer
                    observedApplication = application
                    CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
                } else {
                    state.markInconclusive()
                }
            } else {
                state.markInconclusive()
            }
        } else {
            state.markInconclusive()
        }

        // Close the interval between the initial snapshot and notification registration.
        state.observeCurrent()
    }

    func preserved() -> Bool? {
        guard !stopped else { return nil }
        // Drain notifications already queued during synchronous accessibility work. This
        // also catches an app/window switch followed by a return to the original focus.
        CFRunLoopRunInMode(.defaultMode, 0.001, false)
        state.observeCurrent()
        return state.result()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        if let windowObserver {
            // Remove delivery before releasing the callback's unretained state context.
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(windowObserver), .commonModes)
            if let observedApplication {
                AXObserverRemoveNotification(
                    windowObserver, observedApplication, kAXFocusedWindowChangedNotification as CFString
                )
            }
            self.windowObserver = nil
            observedApplication = nil
        }
    }

    deinit { stop() }
}

private struct MonitoredFocus {
    let pid: pid_t?
    let window: AXUIElement?

    static func capture() -> MonitoredFocus {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return MonitoredFocus(pid: nil, window: nil)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var rawWindow: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &rawWindow)
        let afterPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard afterPID == pid else {
            return MonitoredFocus(pid: afterPID, window: nil)
        }
        guard error == .success, let rawWindow, CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else {
            return MonitoredFocus(pid: pid, window: nil)
        }
        return MonitoredFocus(pid: pid, window: (rawWindow as! AXUIElement))
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

    func observeWindowNotification(_ element: AXUIElement) {
        // Some applications send the new window; others send the application object.
        // A different window in the event must remain recorded even if focus returned
        // before the callback was delivered.
        var rawRole: CFTypeRef?
        AXUIElementSetMessagingTimeout(element, 0.25)
        let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
        if error == .success, rawRole as? String == kAXWindowRole,
           let baselineWindow = baseline.window {
            if !CFEqual(baselineWindow, element) { markChanged() }
        } else {
            // The notification itself says the focused window changed. An application
            // object cannot establish which window was focused at the event's time.
            markChanged()
        }
        observeCurrent()
    }

    func observeCurrent() {
        let current = MonitoredFocus.capture()
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
