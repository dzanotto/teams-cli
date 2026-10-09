import AppKit
import ApplicationServices

/// Only read capabilities are injected here. There is no press, focus, or AX-write operation.
struct TeamsCompatibilityProbe {
    var readerEnvironment: AccessibilityReaderEnvironment = .live
    var capabilities: (AXUIElement) -> CompatibilityCapability = { CompatibilityCapability.read($0) }
    var processIdentity: (NSRunningApplication) -> MediaProcessGeneration? = { app in
        guard !app.isTerminated, let launched = app.launchDate else { return nil }
        return MediaProcessGeneration(pid: app.processIdentifier, launched: launched)
    }

    func run(metadata suppliedMetadata: [String: String]) -> TeamsCompatibilityReport {
        let started = readerEnvironment.uptime()
        var metadata = suppliedMetadata
        var checks = TeamsCompatibilityReport.checkIDs.map {
            CompatibilityCheck(id: $0, outcome: .inconclusive, reason: "not_checked")
        }
        var scanMS: Double = 0
        func set(_ id: String, _ outcome: CompatibilityVerdict, _ reason: String, state: String? = nil) {
            guard let index = checks.firstIndex(where: { $0.id == id }) else { return }
            checks[index] = CompatibilityCheck(id: id, outcome: outcome, reason: reason, state: state)
        }
        func report() -> TeamsCompatibilityReport {
            TeamsCompatibilityReport(metadata: metadata, checks: checks, scanMS: scanMS,
                                     elapsedMS: (readerEnvironment.uptime() - started) * 1_000)
        }

        let apps = readerEnvironment.runningApplications("com.microsoft.teams2")
        if apps.count == 1, let bundleURL = apps[0].application.bundleURL, let bundle = Bundle(url: bundleURL) {
            metadata["teams_version"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            metadata["teams_build"] = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        }
        var processReason = "multiple_teams_processes"
        if apps.isEmpty { processReason = "teams_not_running" }
        if apps.count == 1 { processReason = "one_process" }
        set("teams", apps.count == 1 ? .pass : .inconclusive, processReason)
        let trusted = readerEnvironment.isTrusted()
        set("accessibility", trusted ? .pass : .inconclusive, trusted ? "permission_granted" : "accessibility_denied")
        guard trusted, apps.count == 1 else { return report() }
        let identity = processIdentity(apps[0].application)
        metadata["enhanced_accessibility_before_scan"] = enhancedAccessibility(apps[0].element)
        let timings = CommandTimings(clock: readerEnvironment.uptime)
        let reader = TeamsAccessibilityReader(environment: readerEnvironment, timings: timings, auditMainWindows: true)
        let snapshot: TeamsSnapshot
        let scanStarted = readerEnvironment.uptime()
        do {
            // Hand discovery includes all four buttons and the self-video hand indicator.
            // Audit mode disables main-window exclusion and inspects all shell markers.
            snapshot = try reader.read(control: .hand)
        } catch {
            scanMS = (readerEnvironment.uptime() - scanStarted) * 1_000
            let reason: String
            switch error {
            case TeamsReadError.accessibilityDenied: reason = "accessibility_denied"
            case TeamsReadError.notRunning: reason = "teams_not_running"
            default: reason = "accessibility_read_failed"
            }
            set("inspection", .inconclusive, reason)
            return report()
        }
        scanMS = (readerEnvironment.uptime() - scanStarted) * 1_000
        set("inspection", snapshot.complete ? .pass : .inconclusive,
            snapshot.complete ? "complete_full_scan" : "inspection_incomplete")
        if let focus = snapshot.focusUnchanged {
            set("focus_endpoints", focus ? .pass : .inconclusive, focus ? "unchanged_at_endpoints" : "focus_changed")
        } else {
            set("focus_endpoints", .inconclusive, "focus_unavailable")
        }

        let selection = CallWindowSelection(snapshot.windows)
        let selectionReason = selection.failureReason(complete: snapshot.complete)
        set("call_selection", selectionReason == nil ? .pass : .inconclusive, selectionReason ?? "one_active_call")

        // Only the final scan describes the returned snapshot; earlier retry attempts may be empty.
        let windows = timings.spans.flatMap(\.discoveryScans).last?.windows ?? []
        if !snapshot.complete || windows.contains(where: { $0.mainWindowRecognition == .incomplete }) {
            set("main_window_layout", .inconclusive, "inspection_incomplete")
        } else if windows.contains(where: { $0.mainWindowRecognition == .conflicting }) {
            set("main_window_layout", .fail, "main_shell_contains_call_controls")
        } else if windows.contains(where: { $0.mainWindowRecognition == .mainShell }) {
            set("main_window_layout", .pass, "separate_call_layout")
        } else {
            set("main_window_layout", .inconclusive, "main_shell_not_observed")
        }

        if selectionReason == nil {
            let mic = MicrophoneClassifier.assess(snapshot.windows, complete: snapshot.complete)
            let camera = CameraClassifier.assess(snapshot.windows, complete: snapshot.complete)
            let hand = HandClassifier.assess(snapshot.windows, complete: snapshot.complete)
            let call = CallEndClassifier.assess(snapshot.windows, complete: snapshot.complete)
            let states = [("mic", mic.state.rawValue, mic.reason), ("camera", camera.state.rawValue, camera.reason),
                          ("hand", hand.state.rawValue, hand.reason), ("call", call.state.rawValue, call.reason)]
            for (name, state, reason) in states {
                var outcome: CompatibilityVerdict = reason == nil ? .pass : .fail
                if reason == "own_video_missing" { outcome = .inconclusive }
                set(name + "_state", outcome, reason ?? "recognized", state: state)
            }
            let handles = snapshot.handles[selection.active[0].index]
            for (name, control) in [("mic", MediaControl.microphone), ("camera", .camera), ("hand", .hand), ("call", .call)] {
                let buttons = handles?.buttons(for: control) ?? []
                guard buttons.count == 1 else {
                    set(name + "_press", .fail, buttons.isEmpty ? "control_missing" : "multiple_controls")
                    continue
                }
                let capability = capabilities(buttons[0])
                set(name + "_press", capability.outcome, capability.reason)
            }
        } else if let selectionReason {
            for name in ["mic", "camera", "hand", "call"] {
                set(name + "_state", .inconclusive, selectionReason)
                set(name + "_press", .inconclusive, selectionReason)
            }
        }

        metadata["enhanced_accessibility_after_probe"] = enhancedAccessibility(apps[0].element)
        let after = readerEnvironment.runningApplications("com.microsoft.teams2")
        let sameProcess = identity != nil && after.count == 1 && processIdentity(after[0].application) == identity &&
            snapshot.handles.values.allSatisfy { processIdentity($0.application) == identity }
        if sameProcess {
            set("process_identity", .pass, "same_process")
        } else {
            // A restart during inspection invalidates all structural and state evidence.
            metadata["enhanced_accessibility_after_probe"] = "process_changed_or_unavailable"
            for id in TeamsCompatibilityReport.checkIDs where id != "teams" && id != "accessibility" {
                set(id, .inconclusive, "process_changed_or_unavailable")
            }
        }
        return report()
    }

    private func enhancedAccessibility(_ application: AXUIElement) -> String {
        readerEnvironment.setMessagingTimeout(application, 0.25)
        let (raw, error) = readerEnvironment.copyAttribute(application, "AXEnhancedUserInterface")
        guard error == .success, let raw, CFGetTypeID(raw) == CFBooleanGetTypeID(),
              let value = raw as? Bool else { return "unavailable" }
        return value ? "true" : "false"
    }
}

struct CompatibilityCapability {
    let outcome: CompatibilityVerdict
    let reason: String

    static func read(_ element: AXUIElement, environment: MediaAccessibilityEnvironment = .live) -> Self {
        environment.setMessagingTimeout(element, 0.25)
        let (rawEnabled, enabledError) = environment.copyAttribute(element, kAXEnabledAttribute)
        guard enabledError == .success, let enabled = rawEnabled as? Bool else {
            return Self(outcome: .inconclusive, reason: "enabled_read_unavailable")
        }
        let (rawActions, actionsError) = environment.copyActionNames(element)
        guard actionsError == .success, let actions = rawActions as? [String] else {
            return Self(outcome: .inconclusive, reason: "action_names_unavailable")
        }
        // Action commands first enable AXEnhancedUserInterface under their shared lifecycle.
        // This read-only probe skips that setup, so absence here cannot prove unsupported actions.
        guard actions.contains(kAXPressAction) else {
            return Self(outcome: .inconclusive, reason: "axpress_not_advertised_read_only")
        }
        return Self(outcome: enabled ? .pass : .inconclusive,
                    reason: enabled ? "enabled_and_axpress_available" : "control_disabled")
    }
}
