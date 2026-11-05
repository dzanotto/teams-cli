import ApplicationServices

/// Native attribute calls are injected below the adapters' type and error checks.
struct AccessibilityAttributeClient {
    let makeApplication: (pid_t) -> AXUIElement
    let setMessagingTimeout: (AXUIElement, Float) -> Void
    let copyAttribute: (AXUIElement, String) -> (CFTypeRef?, AXError)
    let setAttribute: (AXUIElement, String, CFTypeRef) -> AXError

    static var live: Self {
        Self(makeApplication: { AXUIElementCreateApplication($0) }, setMessagingTimeout: { element, timeout in
            AXUIElementSetMessagingTimeout(element, timeout)
        }, copyAttribute: { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (value, error)
        }, setAttribute: { element, name, value in
            AXUIElementSetAttributeValue(element, name as CFString, value)
        })
    }
}
