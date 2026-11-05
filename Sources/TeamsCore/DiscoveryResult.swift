/// A final observation and the scan attempts that produced it, independent of diagnostics.
struct DiscoveryResult {
    let snapshot: TeamsSnapshot
    let scans: [DiscoveryScanEvidence]

    /// Unlike compatibility's final-scan check, the audit retains conflicts from every attempt.
    /// Unknown windows remain eligible for full discovery and do not fail the audit.
    var mainWindowAuditPassed: Bool {
        snapshot.complete && !scans.contains { scan in
            scan.windows.contains { window in
                window.mainWindowRecognition == .conflicting || window.mainWindowRecognition == .incomplete
            }
        }
    }
}

struct DiscoveryScanEvidence: Equatable {
    let complete: Bool
    let windows: [WindowDiscoveryEvidence]
}

/// Scan-local facts only: no timings, native handles, or application-provided labels.
struct WindowDiscoveryEvidence: Equatable {
    let window: Int
    let complete: Bool
    let mainWindowRecognition: TeamsMainWindowRecognition.Result?
    let excludedMainWindow: Bool
}
