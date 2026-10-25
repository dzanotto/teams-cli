import Foundation

/// Uses the action lifecycle for AX setup and cleanup, but has no button-press operation.
struct TeamsCompatibilitySetupProbe {
    var probe = TeamsCompatibilityProbe()

    func run(metadata: [String: String]) -> TeamsCompatibilityReport {
        run(metadata: metadata, environment: MediaCommandEnvironment<FocusMonitor>.live)
    }

    func run<Focus: MediaCommandFocus>(metadata suppliedMetadata: [String: String],
                                      environment: MediaCommandEnvironment<Focus>) -> TeamsCompatibilityReport {
        let started = probe.readerEnvironment.uptime()
        var metadata = suppliedMetadata
        var checks = TeamsCompatibilityReport.checkIDs(for: TeamsCompatibilityReport.setupScope).map {
            CompatibilityCheck(id: $0, outcome: .inconclusive, reason: "not_checked")
        }
        var scanMS: Double = 0
        var originalProcess: MediaProcessGeneration?
        func set(_ id: String, _ outcome: CompatibilityVerdict, _ reason: String) {
            guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
            checks[index] = CompatibilityCheck(id: id, outcome: outcome, reason: reason)
        }
        func sameProcess() -> Bool {
            let apps = probe.readerEnvironment.runningApplications("com.microsoft.teams2")
            return originalProcess != nil && apps.count == 1 &&
                probe.processIdentity(apps[0].application) == originalProcess
        }
        func invalidateProcessEvidence() {
            for id in TeamsCompatibilityReport.checkIDs where id != "accessibility" && id != "teams" {
                set(id, .inconclusive, "process_changed_or_unavailable")
            }
            set("accessibility_setup", .inconclusive, "process_changed_or_unavailable")
        }
        // Capture the original value inside the shared lock, immediately before setup.
        let lifecycle = MediaCommandEnvironment(isTrusted: {
            let trusted = environment.isTrusted()
            set("accessibility", trusted ? .pass : .inconclusive,
                trusted ? "permission_granted" : "accessibility_denied")
            return trusted
        }, acquireLock: environment.acquireLock, makeFocus: environment.makeFocus, makeExposure: {
            let apps = probe.readerEnvironment.runningApplications("com.microsoft.teams2")
            guard apps.count == 1, let identity = probe.processIdentity(apps[0].application) else {
                throw MicrophoneCommandError.accessibilitySetupUnavailable
            }
            originalProcess = identity
            metadata["enhanced_accessibility_before_setup"] = probe.enhancedAccessibility(apps[0].element)
            return try environment.makeExposure()
        })

        do {
            try TeamsMediaCommandSupport.perform({ _ in
                guard sameProcess() else {
                    invalidateProcessEvidence()
                    return
                }
                let report = probe.run(metadata: metadata)
                metadata.merge(report.metadata) { _, current in current }
                scanMS = report.scanMS
                for check in report.checks {
                    if let index = checks.firstIndex(where: { $0.id == check.id }) { checks[index] = check }
                }
                // Enabling the attribute alone does not establish button readiness.
                for index in checks.indices where checks[index].reason == "axpress_not_advertised_read_only" {
                    checks[index] = CompatibilityCheck(id: checks[index].id, outcome: .inconclusive,
                                                      reason: "axpress_not_advertised_after_setup")
                }
                let enabled = metadata["enhanced_accessibility_before_scan"] == "true" &&
                    metadata["enhanced_accessibility_after_probe"] == "true"
                set("accessibility_setup", enabled ? .pass : .inconclusive,
                    enabled ? "enhanced_accessibility_enabled" : "enhanced_accessibility_not_confirmed")
            }, environment: lifecycle, onFinalization: { _, restored, focus in
                set("accessibility_cleanup", restored ? .pass : .fail,
                    restored ? "restored_or_original_process_gone" : "accessibility_cleanup_failed")
                set("focus_lifecycle", focus == true ? .pass : .inconclusive,
                    focus == true ? "focus_preserved" : focus == nil ? "focus_unavailable" : "focus_changed")
                if sameProcess() {
                    let apps = probe.readerEnvironment.runningApplications("com.microsoft.teams2")
                    if apps.count == 1 {
                        metadata["enhanced_accessibility_after_cleanup"] = probe.enhancedAccessibility(apps[0].element)
                    }
                }
                if !sameProcess() {
                    metadata["enhanced_accessibility_after_cleanup"] = "process_changed_or_unavailable"
                    invalidateProcessEvidence()
                }
            })
        } catch {
            let reason: String
            switch error {
            case TeamsReadError.accessibilityDenied: reason = "accessibility_denied"
            case MicrophoneCommandError.commandInProgress: reason = "command_in_progress"
            case MicrophoneCommandError.lockUnavailable: reason = "lock_unavailable"
            case MicrophoneCommandError.accessibilityCleanupFailed: reason = "accessibility_cleanup_failed"
            default: reason = "accessibility_setup_unavailable"
            }
            set("accessibility_setup", .inconclusive, reason)
            if reason == "accessibility_cleanup_failed" {
                set("accessibility_cleanup", .fail, reason)
            }
        }
        return TeamsCompatibilityReport(metadata: metadata, checks: checks, scanMS: scanMS,
                                        elapsedMS: (probe.readerEnvironment.uptime() - started) * 1_000,
                                        scope: TeamsCompatibilityReport.setupScope)
    }
}
