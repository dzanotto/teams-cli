import AppKit
import ApplicationServices

/// Temporarily enables Teams' enhanced accessibility tree and restores its prior value.
/// This writes only AXEnhancedUserInterface; it never activates or raises a window.
final class TeamsAccessibilityExposure {
    private let pid: pid_t
    private let launched: Date
    private let application: AXUIElement
    private let original: Bool
    private let attributeName = "AXEnhancedUserInterface" as CFString
    private var needsRestore = false
    private var restorationResult: Bool?

    init() throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2")
            .filter { !$0.isTerminated }
        guard applications.count == 1, let running = applications.first,
              let launched = running.launchDate else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let original = Self.read(application) else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        self.pid = running.processIdentifier
        self.launched = launched
        self.application = application
        self.original = original

        guard sameGeneration() == true else {
            throw MicrophoneCommandError.accessibilitySetupUnavailable
        }
        guard !original else { return }

        // A setter can report an error after applying the value. From this point,
        // cleanup is required regardless of the setter's return code.
        needsRestore = true
        _ = AXUIElementSetAttributeValue(application, attributeName, kCFBooleanTrue)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard sameGeneration() == true, Self.read(application) == true else {
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
        guard let sameBeforeRead = sameGeneration() else { return false }
        guard sameBeforeRead else {
            needsRestore = false
            return true
        }
        if Self.read(application) == original {
            needsRestore = false
            return true
        }
        // Recheck after reading: never intentionally write to a reused process ID.
        guard let sameBeforeWrite = sameGeneration() else { return false }
        guard sameBeforeWrite else {
            needsRestore = false
            return true
        }
        _ = AXUIElementSetAttributeValue(
            application, attributeName, original ? kCFBooleanTrue : kCFBooleanFalse
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        guard let sameAfterWrite = sameGeneration() else { return false }
        guard sameAfterWrite else {
            needsRestore = false
            return true
        }
        guard Self.read(application) == original else { return false }
        needsRestore = false
        return true
    }

    private func sameGeneration() -> Bool? {
        guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
        guard !running.isTerminated else { return false }
        guard let currentLaunch = running.launchDate else { return nil }
        return currentLaunch == launched
    }

    private static func read(_ application: AXUIElement) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return raw as? Bool
    }

    // Emergency fallback when a caller exits without explicitly finalizing cleanup.
    deinit { restore() }
}
