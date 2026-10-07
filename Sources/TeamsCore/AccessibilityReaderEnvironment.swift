import AppKit
import ApplicationServices

struct AccessibilityReaderApplication {
    let application: NSRunningApplication
    let element: AXUIElement
    let executableName: String?
}

/// Read-only native inputs and timing for discovery. Tests supply synthetic trees.
struct AccessibilityReaderEnvironment {
    let isTrusted: () -> Bool
    let runningApplications: (String) -> [AccessibilityReaderApplication]
    let setMessagingTimeout: (AXUIElement, Float) -> Void
    let copyAttribute: (AXUIElement, String) -> (CFTypeRef?, AXError)
    let copyAttributes: (AXUIElement, [String]) -> (CFArray?, AXError)
    let captureFocus: () -> ReaderFocusSnapshot
    let uptime: () -> TimeInterval
    let sleep: (TimeInterval) -> Void

    static var live: Self {
        Self(isTrusted: { AXIsProcessTrusted() }, runningApplications: { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { app in
                AccessibilityReaderApplication(application: app,
                                               element: AXUIElementCreateApplication(app.processIdentifier),
                                               executableName: app.executableURL?.lastPathComponent)
            }
        }, setMessagingTimeout: { element, timeout in
            AXUIElementSetMessagingTimeout(element, timeout)
        }, copyAttribute: { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (value, error)
        }, copyAttributes: { element, names in
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
            return (values, error)
        }, captureFocus: ReaderFocusSnapshot.capture, uptime: {
            ProcessInfo.processInfo.systemUptime
        }, sleep: { Thread.sleep(forTimeInterval: $0) })
    }
}

/// Endpoint comparison for status reads; action monitoring also observes transient changes.
struct ReaderFocusSnapshot {
    let pid: pid_t?
    let window: AXUIElement?

    static func capture() -> ReaderFocusSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ReaderFocusSnapshot(pid: nil, window: nil)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var raw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &raw)
        let window: AXUIElement? = raw.flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        return ReaderFocusSnapshot(pid: app.processIdentifier, window: window)
    }

    func matches(_ other: ReaderFocusSnapshot) -> Bool? {
        guard let pid, let otherPID = other.pid else { return nil }
        guard pid == otherPID else { return false }
        guard let window, let otherWindow = other.window else { return nil }
        return CFEqual(window, otherWindow)
    }
}
