import AppKit
import ApplicationServices

struct MediaProcessGeneration: Equatable {
    let pid: pid_t
    let launched: Date
}

/// Native operations used by media discovery and dispatch. Injectable so their
/// ordering and preflight lifetime can be tested without accessing Teams.
protocol MediaAccessibilityClient {
    var uptime: TimeInterval { get }
    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot
    func generation(of application: NSRunningApplication) -> MediaProcessGeneration?
    func processMatches(pid: pid_t, launched: Date) -> Bool
    func canPress(_ element: AXUIElement) -> Bool
    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef?
    func press(_ element: AXUIElement) -> AXError
}

struct SystemMediaAccessibilityClient: MediaAccessibilityClient {
    private let reader = TeamsAccessibilityReader()

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        try reader.read(control: control, timeout: timeout)
    }

    func generation(of application: NSRunningApplication) -> MediaProcessGeneration? {
        guard let launched = application.launchDate else { return nil }
        return MediaProcessGeneration(pid: application.processIdentifier, launched: launched)
    }

    func processMatches(pid: pid_t, launched: Date) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: pid) else { return false }
        return !application.isTerminated && application.launchDate == launched
    }

    func canPress(_ element: AXUIElement) -> Bool {
        guard value(element, kAXEnabledAttribute) as? Bool == true else { return false }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success &&
            (actions as? [String] ?? []).contains(kAXPressAction)
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }

    func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}
