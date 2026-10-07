import AppKit
import ApplicationServices

/// A registration owns its cleanup, including when its owner exits without calling stop().
final class FocusObservation {
    private var cancellation: (() -> Void)?

    init(cancel: @escaping () -> Void) { cancellation = cancel }

    func cancel() {
        let cancel = cancellation
        cancellation = nil
        cancel?()
    }

    deinit { cancel() }
}

/// Native reads and subscriptions are injected together so tests never alter desktop focus.
struct FocusMonitoringEnvironment {
    let capture: () -> MonitoredFocus
    let observeActivation: (@escaping @Sendable (pid_t?) -> Void) -> FocusObservation
    /// Nil means that creating or registering the AX observer failed.
    let observeWindow: (pid_t, @escaping (AXUIElement) -> Void) -> FocusObservation?
    let role: (AXUIElement) -> String?
    let drainNotifications: () -> Void

    static var live: Self {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let runLoop = CFRunLoopGetCurrent()
        return Self(capture: MonitoredFocus.capture, observeActivation: { handler in
            let observer = notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { notification in
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                handler(application?.processIdentifier)
            }
            return FocusObservation { notificationCenter.removeObserver(observer) }
        }, observeWindow: { pid, handler in
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            var observer: AXObserver?
            let created = AXObserverCreate(pid, { _, element, _, context in
                guard let context else { return }
                let callback = Unmanaged<FocusWindowCallback>.fromOpaque(context).takeUnretainedValue()
                callback.handler(element)
            }, &observer)
            guard created == .success, let observer else { return nil }
            let callback = FocusWindowCallback(handler: handler)
            let registered = AXObserverAddNotification(
                observer, application, kAXFocusedWindowChangedNotification as CFString,
                Unmanaged.passUnretained(callback).toOpaque()
            )
            guard registered == .success else { return nil }
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
            return FocusObservation {
                // Keep the callback context alive until native delivery has been removed.
                withExtendedLifetime(callback) {
                    CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
                    AXObserverRemoveNotification(observer, application, kAXFocusedWindowChangedNotification as CFString)
                }
            }
        }, role: { element in
            var rawRole: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, 0.25)
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
            return error == .success ? rawRole as? String : nil
        }, drainNotifications: {
            CFRunLoopRunInMode(.defaultMode, 0.001, false)
        })
    }
}

private final class FocusWindowCallback {
    let handler: (AXUIElement) -> Void

    init(handler: @escaping (AXUIElement) -> Void) { self.handler = handler }
}
