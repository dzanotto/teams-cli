import Foundation

/// Read-only qualification tool. Compiled with TeamsCore sources by audit-main-window.sh.
/// Uses the normal full traversal; never performs an action or enables an exclusion.
@main
enum MainWindowAudit {
    static func main() throws {
        let timings = CommandTimings()
        let result = try TeamsAccessibilityReader(environment: .live, timings: timings,
                                                  mode: .audit).readWithEvidence()
        timings.detail("focus_unchanged_at_endpoints", result.snapshot.focusUnchanged.map(String.init) ?? "unknown")
        let exitCode: Int32 = result.mainWindowAuditPassed ? 0 : 1
        try timings.emit(command: "main-window-audit", exitCode: exitCode) { text in
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
        exit(exitCode)
    }
}
