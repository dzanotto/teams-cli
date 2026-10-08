import AppKit
import ApplicationServices

/// Native reads used by press eligibility and process identity checks.
struct MediaAccessibilityEnvironment {
    let runningApplication: (pid_t) -> NSRunningApplication?
    let isTerminated: (NSRunningApplication) -> Bool
    let launchDate: (NSRunningApplication) -> Date?
    let setMessagingTimeout: (AXUIElement, Float) -> Void
    let copyAttribute: (AXUIElement, String) -> (CFTypeRef?, AXError)
    let copyActionNames: (AXUIElement) -> (CFArray?, AXError)

    static var live: Self {
        Self(runningApplication: { NSRunningApplication(processIdentifier: $0) },
             isTerminated: { $0.isTerminated }, launchDate: { $0.launchDate },
             setMessagingTimeout: { element, timeout in
            AXUIElementSetMessagingTimeout(element, timeout)
        }, copyAttribute: { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (value, error)
        }, copyActionNames: { element in
            var actions: CFArray?
            let error = AXUIElementCopyActionNames(element, &actions)
            return (actions, error)
        })
    }
}
