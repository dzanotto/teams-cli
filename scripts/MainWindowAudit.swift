import Foundation

/// Read-only qualification tool. Compiled with TeamsCore sources by audit-main-window.sh.
/// Uses the normal full traversal; never performs an action or enables an exclusion.
@main
enum MainWindowAudit {
    static func main() throws {
        let timings = CommandTimings()
        let snapshot = try TeamsAccessibilityReader(environment: .live, timings: timings,
                                                    auditMainWindows: true).read()
        timings.detail("focus_unchanged_at_endpoints", snapshot.focusUnchanged.map(String.init) ?? "unknown")
        let windows = timings.spans.flatMap(\.discoveryScans).flatMap(\.windows)
        let inconclusive = windows.contains { $0.mainWindowRecognition == .conflicting || $0.mainWindowRecognition == .incomplete }
        let exitCode: Int32 = snapshot.complete && !inconclusive ? 0 : 1
        try timings.emit(command: "main-window-audit", exitCode: exitCode) { text in
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
        exit(exitCode)
    }
}
