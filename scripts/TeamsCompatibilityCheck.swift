import Foundation

/// Separate repository diagnostic, compiled with TeamsCore. Never invokes an action controller.
@main
enum TeamsCompatibilityCheck {
    static let usage = """
    Usage: bash scripts/check-teams-compatibility.sh [options]
      --language CODE       Teams UI language, supplied by you (otherwise unknown).
      --baseline FILE       Compare with a previously saved passing JSON report.
      --save-baseline FILE  Save this report as a baseline, only if all checks pass.
      --output FILE         JSON report destination (default: .build/teams-compatibility/latest.json).
      --json                Print JSON instead of the readable summary.
      --help                Show this help without reading Teams.

    Keep the Teams main window open and join one non-held call. Leave your self-video
    tile visible. Run from a terminal with Accessibility permission; keep focus still.
    This checks the current checkout's TeamsCore, not an installed teams-cli binary.
    No controls are pressed, no AX attributes are written, and Teams is not activated.
    PASS covers read-only discovery and advertised capabilities only, not live actions.
    Missing AXPress is INCONCLUSIVE: the CLI's enhanced Accessibility setup is not run.
    Exit codes: 0 PASS/help, 1 FAIL, 2 INCONCLUSIVE, 64 invalid arguments, 74 file/report error.
    """

    struct Options {
        var language = "unknown"
        var baseline: String?
        var saveBaseline: String?
        var output = ProcessInfo.processInfo.environment["TEAMS_COMPATIBILITY_DEFAULT_OUTPUT"]
        var json = false

        init(_ arguments: [String]) throws {
            var index = 0
            var seen = Set<String>()
            while index < arguments.count {
                let argument = arguments[index]
                guard seen.insert(argument).inserted else { throw ArgumentError.invalid }
                if argument == "--json" {
                    json = true
                    index += 1
                    continue
                }
                guard ["--language", "--baseline", "--save-baseline", "--output"].contains(argument),
                      index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("--") else { throw ArgumentError.invalid }
                let value = arguments[index + 1]
                switch argument {
                case "--language":
                    guard value.range(of: "^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
                        throw ArgumentError.invalid
                    }
                    language = value
                case "--baseline": baseline = value
                case "--save-baseline": saveBaseline = value
                default: output = value
                }
                index += 2
            }
            // A failed run must never overwrite its comparison baseline via --output.
            if let output {
                let destination = Self.resolved(output)
                if [baseline, saveBaseline].compactMap({ $0 }).contains(where: { Self.resolved($0) == destination }) {
                    throw ArgumentError.invalid
                }
            }
        }

        static func resolved(_ path: String) -> URL {
            URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    enum ArgumentError: Error { case invalid }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return
        }
        let options: Options
        do { options = try Options(arguments) }
        catch {
            stderr("Invalid arguments or overlapping report/baseline paths.\n" + usage)
            exit(64)
        }
        do {
            // Validate input before touching Teams or replacing any output file.
            let baseline = try options.baseline.map {
                let report = try JSONDecoder().decode(TeamsCompatibilityReport.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
                try report.validateBaseline()
                return report
            }
            let environment = ProcessInfo.processInfo.environment
            let metadata = [
                "teams_version": "unknown", "teams_build": "unknown",
                "teams_language": options.language, "teams_language_source": "user_supplied_or_unknown",
                "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "cli_version": BuildVersion.value,
                "source_revision": environment["TEAMS_COMPATIBILITY_SOURCE_REVISION"] ?? "unknown",
                "source_dirty": environment["TEAMS_COMPATIBILITY_SOURCE_DIRTY"] ?? "unknown"
            ]
            var report = TeamsCompatibilityProbe().run(metadata: metadata)
            if let baseline { report.comparison = try report.comparing(to: baseline) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(report)
            data.append(0x0A)
            if let output = options.output { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
            if let saveBaseline = options.saveBaseline {
                if report.outcome == .pass {
                    try report.validateBaseline()
                    try data.write(to: URL(fileURLWithPath: saveBaseline), options: .atomic)
                } else {
                    stderr("Baseline unchanged: this run did not pass all read-only checks.")
                }
            }
            if options.json {
                FileHandle.standardOutput.write(data)
            } else {
                print(summary(report))
                if let output = options.output { print("JSON report: \(output)") }
            }
            exit(report.exitCode)
        } catch CompatibilityReportError.invalidBaseline {
            stderr("Invalid baseline: expected a complete passing schema-v1 read-only report.")
            exit(74)
        } catch {
            stderr("Cannot read or write the report/baseline: \(error.localizedDescription)")
            exit(74)
        }
    }

    static func summary(_ report: TeamsCompatibilityReport) -> String {
        let metadata = report.metadata
        var lines = [
            "\(report.outcome.rawValue): Teams read-only compatibility (actions not tested)",
            "Teams \(metadata["teams_version"] ?? "unknown") (build \(metadata["teams_build"] ?? "unknown")); language \(metadata["teams_language"] ?? "unknown")",
            "\(metadata["macos_version"] ?? "unknown"); CLI source \(metadata["cli_version"] ?? "unknown") @ \(metadata["source_revision"] ?? "unknown") (dirty: \(metadata["source_dirty"] ?? "unknown"))"
        ]
        if let before = metadata["enhanced_accessibility_before_scan"] {
            lines.append("Enhanced Accessibility: \(before) -> \(metadata["enhanced_accessibility_after_probe"] ?? "not_checked") (action setup not run)")
        }
        for check in report.checks {
            let state = check.state.map { " [\($0)]" } ?? ""
            lines.append("\(check.outcome.rawValue) \(check.id): \(check.reason)\(state)")
        }
        if report.checks.contains(where: { $0.reason == "axpress_not_advertised_read_only" }) {
            lines.append("NOTE: Missing AXPress in read-only mode does not establish broken actions. CLI actions temporarily enable enhanced Accessibility before checking AXPress.")
        }
        lines.append(String(format: "Full scan: %.1f ms; total probe: %.1f ms (compilation excluded)", report.scanMS, report.elapsedMS))
        if let comparison = report.comparison {
            lines.append("Baseline: \(comparison.baselineRecordedAt); \(comparison.checks.count) check changes")
            for change in comparison.checks {
                lines.append("  \(change.id): \(change.before.rawValue) -> \(change.after.rawValue) (\(change.reason))")
            }
            for change in comparison.metadata {
                lines.append("  \(change.field): \(change.before ?? "unknown") -> \(change.after ?? "unknown")")
            }
            lines.append(String(format: "Scan delta: %+.1f ms", comparison.scanDeltaMS))
            if comparison.slowdown { lines.append("WARNING: scan exceeds 2x baseline and adds over 250 ms; repeat under similar conditions.") }
        }
        return lines.joined(separator: "\n")
    }

    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
