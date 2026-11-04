import ApplicationServices

protocol MediaCommandFocus {
    func preserved() -> Bool?
    func stop()
}

extension FocusMonitor: MediaCommandFocus {}

/// Keeps lifecycle tests independent of the desktop while exercising the real lock and cleanup.
struct MediaCommandEnvironment<Focus: MediaCommandFocus> {
    let isTrusted: () -> Bool
    let acquireLock: () throws -> MediaCommandLock
    let makeFocus: () -> Focus
    let makeExposure: () throws -> TeamsAccessibilityExposure
}

extension MediaCommandEnvironment where Focus == FocusMonitor {
    static var live: Self {
        Self(isTrusted: { AXIsProcessTrusted() }, acquireLock: { try MediaCommandLock() },
             makeFocus: { FocusMonitor() }, makeExposure: { try TeamsAccessibilityExposure() })
    }
}

/// Shared lifecycle: lock, observe focus, expose AX, act, restore, finalize.
enum TeamsMediaCommandSupport {
    static func perform<Result, Focus: MediaCommandFocus>(
        _ operation: (Focus) throws -> Result,
        environment: MediaCommandEnvironment<Focus>,
        timings: CommandTimings? = nil,
        onFinalizationFailure: (Result, String, Bool?) -> Result
    ) throws -> Result {
        try perform(operation, environment: environment, timings: timings, onFinalization: { result, restored, focus in
            guard restored, focus == true else {
                let focusReason = focus == nil ? "focus_unavailable" : "focus_changed"
                let reason = !restored ? "accessibility_cleanup_failed" : focusReason
                return onFinalizationFailure(result, reason, focus)
            }
            return result
        })
    }

    /// Call end permits Teams to change focus, but still observes and reports it.
    static func perform<Result, Focus: MediaCommandFocus>(
        _ operation: (Focus) throws -> Result,
        environment: MediaCommandEnvironment<Focus>,
        timings: CommandTimings? = nil,
        onFinalization: (Result, Bool, Bool?) -> Result
    ) throws -> Result {
        guard environment.isTrusted() else { throw TeamsReadError.accessibilityDenied }
        let commandLock = try timings.measure("lock_acquire", environment.acquireLock)
        defer { timings.measure("lock_release", commandLock.release) }
        let focus = timings.measure("focus_start", environment.makeFocus)
        defer { timings.measure("focus_stop", focus.stop) }
        let exposure: TeamsAccessibilityExposure
        do {
            exposure = try timings.measure("accessibility_setup", environment.makeExposure)
        } catch {
            // Initialization finalizes any setup cleanup before throwing. Drain focus
            // observations while monitoring is still alive; no cleanup writes follow.
            _ = timings.measure("focus_check", focus.preserved)
            throw error
        }
        // restore() caches both success and failure. Explicit finalization below
        // prevents deferred/deinit writes after the final focus observation.
        defer { _ = exposure.restore() }
        let result: Result
        do {
            result = try operation(focus)
        } catch {
            let restored = timings.measure("accessibility_cleanup", exposure.restore)
            _ = timings.measure("focus_check", focus.preserved)
            guard restored else { throw MediaCommandError.accessibilityCleanupFailed }
            throw error
        }
        let restored = timings.measure("accessibility_cleanup", exposure.restore)
        let finalFocus = timings.measure("focus_check", focus.preserved)
        return onFinalization(result, restored, finalFocus)
    }
}
