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
        let windowClient = FocusWindowObserverClient<AXObserver>.live
        return Self(capture: MonitoredFocus.capture, observeActivation: { handler in
            observeActivation(in: notificationCenter, handler: handler)
        }, observeWindow: { pid, handler in
            windowClient.observe(pid: pid, handler: handler)
        }, role: { element in
            var rawRole: CFTypeRef?
            AXUIElementSetMessagingTimeout(element, 0.25)
            let error = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &rawRole)
            return error == .success ? rawRole as? String : nil
        }, drainNotifications: {
            CFRunLoopRunInMode(.defaultMode, 0.001, false)
        })
    }

    static func observeActivation(in notificationCenter: NotificationCenter,
                                  handler: @escaping @Sendable (pid_t?) -> Void) -> FocusObservation {
        let observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            handler(application?.processIdentifier)
        }
        return FocusObservation { notificationCenter.removeObserver(observer) }
    }
}
