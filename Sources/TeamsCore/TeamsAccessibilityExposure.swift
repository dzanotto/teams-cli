import AppKit
import ApplicationServices

protocol AccessibilityExposureClient {
    func sameGeneration() -> Bool?
    func read() -> Bool?
    /// Setter success is not evidence; the subsequent readback determines the result.
    func write(_ value: Bool)
    func waitForValue(_ expected: Bool) -> AccessibilityExposureReadiness.Result
}

/// Temporarily enables Teams' enhanced accessibility tree and restores its prior value.
/// This writes only AXEnhancedUserInterface; it never activates or raises a window.
final class TeamsAccessibilityExposure {
    private let client: any AccessibilityExposureClient
    private let original: Bool
    private var needsRestore = false
    private var restorationResult: Bool?

    convenience init() throws {
        try self.init(client: SystemAccessibilityExposureClient())
    }

    init(client: any AccessibilityExposureClient) throws {
        guard let original = client.read() else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        self.client = client
        self.original = original

        guard client.sameGeneration() == true else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        guard !original else { return }

        // A setter can report an error after applying the value. From this point,
        // cleanup is required regardless of the setter's return code.
        needsRestore = true
        client.write(true)
        guard client.waitForValue(true) == .confirmed else {
            guard restore() else {
                throw MicrophoneCommandError.accessibilityCleanupFailed
            }
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
    }

    /// Finalizes cleanup before the caller takes its final focus snapshot. The result
    /// is cached even on failure, so defer/deinit cannot write after that snapshot.
    /// Returns true after verified restoration, or when the original process is gone.
    @discardableResult
    func restore() -> Bool {
        if let restorationResult { return restorationResult }
        let restored = restoreOnce()
        restorationResult = restored
        return restored
    }

    private func restoreOnce() -> Bool {
        guard needsRestore else { return true }
        guard let sameBeforeRead = client.sameGeneration() else { return false }
        guard sameBeforeRead else {
            needsRestore = false
            return true
        }
        if client.read() == original {
            needsRestore = false
            return true
        }
        // Recheck after reading: never intentionally write to a reused process ID.
        guard let sameBeforeWrite = client.sameGeneration() else { return false }
        guard sameBeforeWrite else {
            needsRestore = false
            return true
        }
        client.write(original)
        switch client.waitForValue(original) {
        case .confirmed, .processGone:
            needsRestore = false
            return true
        case .unavailable, .timedOut:
            return false
        }
    }

    // Emergency fallback when a caller exits without explicitly finalizing cleanup.
    deinit { restore() }
}

private struct SystemAccessibilityExposureClient: AccessibilityExposureClient {
    let pid: pid_t
    let launched: Date
    let application: AXUIElement

    init() throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2")
            .filter { !$0.isTerminated }
        guard applications.count == 1, let running = applications.first,
              let launched = running.launchDate else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        pid = running.processIdentifier
        self.launched = launched
        application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
    }

    func write(_ value: Bool) {
        _ = AXUIElementSetAttributeValue(
            application, "AXEnhancedUserInterface" as CFString, value ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    func waitForValue(_ expected: Bool) -> AccessibilityExposureReadiness.Result {
        // Later setup/cleanup reads retain the usual per-message timeout.
        defer { AXUIElementSetMessagingTimeout(application, 0.25) }
        return AccessibilityExposureReadiness(sameGeneration: sameGeneration, read: { timeout in
            AXUIElementSetMessagingTimeout(self.application, Float(timeout))
            return self.read()
        }).waitFor(expected)
    }

    func sameGeneration() -> Bool? {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
        guard !running.isTerminated else { return false }
        guard let currentLaunch = running.launchDate else { return nil }
        return currentLaunch == launched
    }

    func read() -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return raw as? Bool
    }
}
