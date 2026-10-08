import ApplicationServices

/// Keeps observer ownership and callback lifetime testable with local observer tokens.
struct FocusWindowObserverClient<Observer> {
    let makeApplication: (pid_t) -> AXUIElement
    let create: (pid_t) -> (Observer?, AXError)
    let register: (Observer, AXUIElement, UnsafeMutableRawPointer) -> AXError
    let addSource: (Observer) -> Void
    let removeSource: (Observer) -> Void
    let unregister: (Observer, AXUIElement) -> Void

    func observe(pid: pid_t, handler: @escaping (AXUIElement) -> Void) -> FocusObservation? {
        let application = makeApplication(pid)
        let (observer, error) = create(pid)
        guard error == .success, let observer else { return nil }
        let callback = FocusWindowCallback(handler: handler)
        let context = Unmanaged.passUnretained(callback).toOpaque()
        guard register(observer, application, context) == .success else { return nil }
        addSource(observer)
        return makeObservation(observer: observer, application: application, callback: callback)
    }

    private func makeObservation(observer: Observer, application: AXUIElement,
                                 callback: FocusWindowCallback) -> FocusObservation {
        FocusObservation {
            // The native context is unretained; own it until both cleanup calls finish.
            withExtendedLifetime(callback) {
                removeSource(observer)
                unregister(observer, application)
            }
        }
    }
}

extension FocusWindowObserverClient where Observer == AXObserver {
    static var live: Self {
        let runLoop = CFRunLoopGetCurrent()
        return Self(makeApplication: { pid in
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            return application
        }, create: { pid in
            var observer: AXObserver?
            let error = AXObserverCreate(pid, { _, element, _, context in
                FocusWindowCallback.deliver(element: element, context: context)
            }, &observer)
            return (observer, error)
        }, register: { observer, application, context in
            AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, context)
        }, addSource: { observer in
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        }, removeSource: { observer in
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .commonModes)
        }, unregister: { observer, application in
            AXObserverRemoveNotification(observer, application, kAXFocusedWindowChangedNotification as CFString)
        })
    }
}

final class FocusWindowCallback {
    let handler: (AXUIElement) -> Void

    init(handler: @escaping (AXUIElement) -> Void) { self.handler = handler }

    static func deliver(element: AXUIElement, context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let callback = Unmanaged<FocusWindowCallback>.fromOpaque(context).takeUnretainedValue()
        callback.handler(element)
    }
}
