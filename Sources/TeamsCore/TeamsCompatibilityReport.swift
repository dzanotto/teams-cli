import Foundation

enum CompatibilityVerdict: String, Codable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
}

struct CompatibilityCheck: Codable, Equatable {
    let id: String
    let outcome: CompatibilityVerdict
    let reason: String
    var state: String?
}

/// A deliberately small allowlisted report: never serialize AX snapshots or labels.
struct TeamsCompatibilityReport: Codable {
    static let readOnlyScope = "read_only_discovery"
    static let setupScope = "accessibility_setup_discovery"
    static let checkIDs = [
        "accessibility", "teams", "inspection", "call_selection", "main_window_layout",
        "mic_state", "mic_press", "camera_state", "camera_press", "hand_state", "hand_press",
        "call_state", "call_press", "focus_endpoints", "process_identity"
    ]

    static func checkIDs(for scope: String) -> [String] {
        scope == setupScope ? checkIDs + ["accessibility_setup", "accessibility_cleanup", "focus_lifecycle"] : checkIDs
    }

    let schemaVersion: Int
    let scope: String
    let recordedAt: String
    let metadata: [String: String]
    let outcome: CompatibilityVerdict
    let checks: [CompatibilityCheck]
    let scanMS: Double
    let elapsedMS: Double
    var comparison: CompatibilityComparison?

    enum CodingKeys: String, CodingKey {
        case scope, metadata, outcome, checks, comparison
        case schemaVersion = "schema_version", recordedAt = "recorded_at"
        case scanMS = "scan_ms", elapsedMS = "elapsed_ms"
    }

    init(metadata: [String: String], checks: [CompatibilityCheck], scanMS: Double, elapsedMS: Double,
         scope: String = TeamsCompatibilityReport.readOnlyScope) {
        schemaVersion = 1
        self.scope = scope
        recordedAt = ISO8601DateFormatter().string(from: Date())
        self.metadata = metadata
        self.checks = checks
        outcome = Self.verdict(checks, scope: scope)
        self.scanMS = scanMS
        self.elapsedMS = elapsedMS
    }

    var exitCode: Int32 {
        switch outcome {
        case .pass: return 0
        case .fail: return 1
        case .inconclusive: return 2
        }
    }

    static func verdict(_ checks: [CompatibilityCheck], scope: String = readOnlyScope) -> CompatibilityVerdict {
        if checks.contains(where: { $0.outcome == .fail }) { return .fail }
        let required = checkIDs(for: scope)
        guard [readOnlyScope, setupScope].contains(scope),
              checks.count == required.count, Set(checks.map(\.id)) == Set(required),
              checks.allSatisfy({ $0.outcome == .pass }) else { return .inconclusive }
        return .pass
    }

    func validateBaseline(expectedScope: String? = nil) throws {
        guard schemaVersion == 1, [Self.readOnlyScope, Self.setupScope].contains(scope),
              expectedScope == nil || scope == expectedScope,
              outcome == .pass, Self.verdict(checks, scope: scope) == .pass,
              scanMS.isFinite, scanMS >= 0, elapsedMS.isFinite, elapsedMS >= 0 else {
            throw CompatibilityReportError.invalidBaseline
        }
    }

    func comparing(to baseline: Self) throws -> CompatibilityComparison {
        try baseline.validateBaseline(expectedScope: scope)
        let previous = Dictionary(uniqueKeysWithValues: baseline.checks.map { ($0.id, $0) })
        let changes = checks.compactMap { check -> CompatibilityComparison.CheckChange? in
            guard let old = previous[check.id], old.outcome != check.outcome || old.reason != check.reason else { return nil }
            // Ordinary media state changes are expected and are not regressions.
            return .init(id: check.id, before: old.outcome, after: check.outcome, reason: check.reason)
        }
        let metadataChanges = Set(metadata.keys).union(baseline.metadata.keys).sorted().compactMap { key in
            guard metadata[key] != baseline.metadata[key] else { return nil as CompatibilityComparison.MetadataChange? }
            return CompatibilityComparison.MetadataChange(field: key, before: baseline.metadata[key], after: metadata[key])
        }
        return CompatibilityComparison(baselineRecordedAt: baseline.recordedAt, checks: changes,
                                       metadata: metadataChanges, scanDeltaMS: scanMS - baseline.scanMS,
                                       scanRatio: baseline.scanMS > 0 ? scanMS / baseline.scanMS : nil,
                                       slowdown: scanMS > baseline.scanMS * 2 && scanMS - baseline.scanMS > 250)
    }
}

enum CompatibilityReportError: Error {
    case invalidBaseline
}

struct CompatibilityComparison: Codable {
    struct CheckChange: Codable {
        let id: String
        let before: CompatibilityVerdict
        let after: CompatibilityVerdict
        let reason: String
    }

    struct MetadataChange: Codable {
        let field: String
        let before: String?
        let after: String?
    }

    let baselineRecordedAt: String
    let checks: [CheckChange]
    let metadata: [MetadataChange]
    let scanDeltaMS: Double
    let scanRatio: Double?
    let slowdown: Bool

    enum CodingKeys: String, CodingKey {
        case checks, metadata, slowdown
        case baselineRecordedAt = "baseline_recorded_at", scanDeltaMS = "scan_delta_ms", scanRatio = "scan_ratio"
    }
}
