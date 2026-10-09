import Foundation

/// Bounded diagnostics from traversal. Never reads AX or decides scan eligibility.
final class AccessibilityDiscoveryTimings {
    struct Scan: Encodable {
        var complete = false
        var windows: [Window] = []
    }

    struct Window: Encodable {
        let window: Int
        var complete = true
        var durationMS: Double = 0
        var visitedNodes = 0
        var aggregates: [String: CommandTimings.Aggregate] = [:]
        var branches: [Branch] = [Branch(id: 0, parentID: nil, rootDepth: 0, splitLevel: 0)]
        var mainWindowRecognition: TeamsMainWindowRecognition.Result?
        var excludedMainWindow = false

        enum CodingKeys: String, CodingKey {
            case window, complete, aggregates, branches
            case durationMS = "duration_ms", visitedNodes = "visited_nodes"
            case mainWindowRecognition = "main_window_recognition"
            case excludedMainWindow = "excluded_main_window"
        }
    }

    struct Branch: Encodable {
        let id: Int
        let parentID: Int?
        let rootDepth: Int?
        let splitLevel: Int
        var overflow = false
        var rootRole: String?
        var visitedNodes = 0
        var maxDepth: Int?
        var roles: [String: Int] = [:]
        var controls: [String: Int] = [:]
        var aggregates: [String: CommandTimings.Aggregate] = [:]

        enum CodingKeys: String, CodingKey {
            case id, overflow, roles, controls, aggregates
            case parentID = "parent_id", rootDepth = "root_depth", rootRole = "root_role"
            case visitedNodes = "visited_nodes", maxDepth = "max_depth"
        }
    }

    private let clock: () -> TimeInterval
    private var windowStartedAt: TimeInterval = 0
    private var windowIndex = 0
    private var overflowBranch: Int?
    private(set) var scan = Scan()

    // Normalize unknown/custom roles rather than recording arbitrary strings from an application.
    private static let roles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDrawer", "AXGroup", "AXSplitGroup",
        "AXScrollArea", "AXWebArea", "AXToolbar", "AXButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuItem", "AXMenuBar", "AXTabGroup",
        "AXTable", "AXRow", "AXColumn", "AXCell", "AXOutline", "AXList", "AXTextField",
        "AXTextArea", "AXStaticText", "AXImage", "AXLink", "AXHeading", "AXSlider",
        "AXScrollBar", "AXProgressIndicator", "AXBusyIndicator", "AXUnknown"
    ]
    private static let controls: Set<String> = [
        "microphone-button", "video-button", "hangup-button", "resume-button", "raisehands-button"
    ]

    init(clock: @escaping () -> TimeInterval) { self.clock = clock }

    func beginWindow(_ index: Int) {
        windowIndex = scan.windows.count
        scan.windows.append(Window(window: index))
        overflowBranch = nil
        windowStartedAt = clock()
    }

    func endWindow() {
        scan.windows[windowIndex].durationMS = (clock() - windowStartedAt) * 1_000
    }

    func finish(complete: Bool) { scan.complete = complete }

    func markIncomplete() { scan.windows[windowIndex].complete = false }

    func excludeMainWindow() { scan.windows[windowIndex].excludedMainWindow = true }

    func recordMainWindowRecognition(_ recognition: TeamsMainWindowRecognition) {
        scan.windows[windowIndex].mainWindowRecognition = scan.windows[windowIndex].complete ? recognition.result : .incomplete
    }

    /// Each visited node belongs to one bucket. Descendants split off at the first two forks;
    /// single-child wrappers stay in their parent's bucket. IDs are local to this window/scan.
    func branchForChild(of parent: Int, depth: Int, siblingCount: Int) -> Int {
        let level = scan.windows[windowIndex].branches[parent].splitLevel
        guard siblingCount > 1, level < 2 else { return parent }
        if scan.windows[windowIndex].branches.count < 63 {
            let id = scan.windows[windowIndex].branches.count
            scan.windows[windowIndex].branches.append(
                Branch(id: id, parentID: parent, rootDepth: depth, splitLevel: level + 1))
            return id
        }
        if let overflowBranch { return overflowBranch }
        let id = scan.windows[windowIndex].branches.count
        scan.windows[windowIndex].branches.append(
            Branch(id: id, parentID: nil, rootDepth: nil, splitLevel: 2, overflow: true))
        overflowBranch = id
        return id
    }

    func visit(branch: Int, depth: Int) {
        scan.windows[windowIndex].visitedNodes += 1
        scan.windows[windowIndex].branches[branch].visitedNodes += 1
        let deepest = scan.windows[windowIndex].branches[branch].maxDepth ?? depth
        scan.windows[windowIndex].branches[branch].maxDepth = max(deepest, depth)
    }

    func recordRole(_ role: String, branch: Int) {
        let safeRole = role.isEmpty ? "unavailable" : Self.roles.contains(role) ? role : "other"
        if scan.windows[windowIndex].branches[branch].visitedNodes == 1,
           !scan.windows[windowIndex].branches[branch].overflow {
            scan.windows[windowIndex].branches[branch].rootRole = safeRole
        }
        scan.windows[windowIndex].branches[branch].roles[safeRole, default: 0] += 1
    }

    func recordControl(_ identifier: String, branch: Int) {
        guard Self.controls.contains(identifier) else { return }
        scan.windows[windowIndex].branches[branch].controls[identifier, default: 0] += 1
    }

    func recordRequest(_ group: String, durationMS: Double, branch: Int) {
        scan.windows[windowIndex].aggregates[group, default: .init()].count += 1
        scan.windows[windowIndex].aggregates[group, default: .init()].durationMS += durationMS
        scan.windows[windowIndex].branches[branch].aggregates[group, default: .init()].count += 1
        scan.windows[windowIndex].branches[branch].aggregates[group, default: .init()].durationMS += durationMS
    }
}
