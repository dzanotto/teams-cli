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
    private let reader: TeamsAccessibilityReader
    private let environment: MediaAccessibilityEnvironment

    init(environment: MediaAccessibilityEnvironment = .live, timings: CommandTimings? = nil) {
        reader = TeamsAccessibilityReader(environment: .live, timings: timings)
        self.environment = environment
    }

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        try reader.read(control: control, timeout: timeout)
    }

    func generation(of application: NSRunningApplication) -> MediaProcessGeneration? {
        guard let launched = environment.launchDate(application) else { return nil }
        return MediaProcessGeneration(pid: application.processIdentifier, launched: launched)
    }

    func processMatches(pid: pid_t, launched: Date) -> Bool {
        guard let application = environment.runningApplication(pid) else { return false }
        return !environment.isTerminated(application) && environment.launchDate(application) == launched
    }

    func canPress(_ element: AXUIElement) -> Bool {
        guard value(element, kAXEnabledAttribute) as? Bool == true else { return false }
        let (actions, error) = environment.copyActionNames(element)
        return error == .success &&
            (actions as? [String] ?? []).contains(kAXPressAction)
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        environment.setMessagingTimeout(element, 0.25)
        let (result, error) = environment.copyAttribute(element, name)
        return error == .success ? result : nil
    }

    func press(_ element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}
