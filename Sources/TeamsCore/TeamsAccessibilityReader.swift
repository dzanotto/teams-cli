import AppKit
import ApplicationServices

public enum TeamsReadError: Error {
    case accessibilityDenied
    case notRunning
    case accessibilityFailure(Int32)
}

public enum MediaControl: String {
    case microphone = "microphone-button"
    case camera = "video-button"
    case call = "hangup-button"
    case hand = "raisehands-button"
}

public struct TeamsSnapshot {
    public let windows: [WindowSnapshot]
    public let complete: Bool
    public let focusUnchanged: Bool?
    var handles: [Int: CallWindowHandles] = [:]
}

struct CallWindowHandles {
    let application: NSRunningApplication
    let window: AXUIElement
    var microphones: [AXUIElement] = []
    var cameras: [AXUIElement] = []
    var hangups: [AXUIElement] = []
    var hands: [AXUIElement] = []
    var ownVideos: [AXUIElement] = []

    func buttons(for control: MediaControl) -> [AXUIElement] {
        switch control {
        case .microphone: return microphones
        case .camera: return cameras
        case .call: return hangups
        case .hand: return hands
        }
    }
}

/// Reads controls only: no activation, events, AX actions, attribute writes, or permission prompts.
public final class TeamsAccessibilityReader {
    private let maxNodes = 12_000
    private let maxDepth = 80
    private let maxSeconds: TimeInterval = 8
    private let mainWindowNodeLimit = 256
    private let mainWindowDepthLimit = 24
    private let environment: AccessibilityReaderEnvironment
    private let timings: CommandTimings?
    private let auditMainWindows: Bool
    private let excludeMainWindows: Bool

    public convenience init() { self.init(environment: .live) }

    init(environment: AccessibilityReaderEnvironment, timings: CommandTimings? = nil,
         auditMainWindows: Bool = false, excludeMainWindows: Bool = true) {
        self.environment = environment
        self.timings = timings
        self.auditMainWindows = auditMainWindows
        self.excludeMainWindows = excludeMainWindows
    }

    public func read(control: MediaControl = .microphone, timeout: TimeInterval = 8) throws -> TeamsSnapshot {
        try timings.measure("discovery") {
            timings?.increment("visited_nodes", by: 0)
            timings?.increment("attribute_calls", by: 0)
            timings?.increment("batch_attribute_calls", by: 0)
            timings?.increment("scan_attempts", by: 0)
            timings?.increment("excluded_main_windows", by: 0)
            let snapshot = try discover(control: control, timeout: timeout)
            timings?.detail("complete", String(snapshot.complete))
            return snapshot
        }
    }

    private func discover(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        guard environment.isTrusted() else { throw TeamsReadError.accessibilityDenied }
        let apps = environment.runningApplications("com.microsoft.teams2")
        guard !apps.isEmpty else { throw TeamsReadError.notRunning }
        let focusBefore = timings.measure("reader_focus_check", environment.captureFocus)
        let deadline = environment.uptime() + min(maxSeconds, max(0, timeout))

        // Chromium enables its native accessibility tree when the browser app's role is read.
        // Teams' web content is hosted by this background helper, not its main application.
        // Helpers can share a bundle ID; query only the browser executable, not renderers/utilities.
        for helper in environment.runningApplications("com.microsoft.teams2.helper") {
            guard helper.executableName == "Microsoft Teams WebView" else { continue }
            environment.setMessagingTimeout(helper.element, 0.25)
            timings?.increment("attribute_calls")
            _ = environment.copyAttribute(helper.element, kAXRoleAttribute)
        }

        var result = try scan(apps, control: control, deadline: deadline)
        // The web tree can appear asynchronously after the role query. Retry once without
        // changing focus or enabling screen-reader mode. The scan itself is bounded.
        if environment.uptime() + 0.25 < deadline && result.complete && !result.windows.contains(where: { window in
            window.controls.contains(where: { $0.identifier == control.rawValue })
        }) {
            timings.measure("discovery_retry_wait") { environment.sleep(0.25) }
            result = try scan(apps, control: control, deadline: deadline)
        }
        return TeamsSnapshot(windows: result.windows, complete: result.complete,
                             focusUnchanged: focusBefore.matches(timings.measure("reader_focus_check", environment.captureFocus)),
                             handles: result.handles)
    }

    private func scan(_ apps: [AccessibilityReaderApplication], control: MediaControl, deadline: TimeInterval) throws -> TeamsSnapshot {
        timings?.increment("scan_attempts")
        let scanTimings = timings?.makeDiscoveryTimings()
        defer {
            if let scanTimings { timings?.recordDiscoveryScan(scanTimings.scan) }
        }
        var visited = Set<AXUIElement>()
        var scheduled = Set<AXUIElement>()
        var complete = true
        var snapshots: [WindowSnapshot] = []
        var handles: [Int: CallWindowHandles] = [:]

        for app in apps {
            let root = app.element
            environment.setMessagingTimeout(root, 0.25)
            timings?.increment("attribute_calls")
            let (rawWindows, error) = environment.copyAttribute(root, kAXWindowsAttribute)
            guard error == .success, let windows = rawWindows as? [AXUIElement] else {
                throw TeamsReadError.accessibilityFailure(error.rawValue)
            }
            for window in windows {
                scanTimings?.beginWindow(snapshots.count + 1)
                defer { scanTimings?.endWindow() }
                var mainWindowRecognition = TeamsMainWindowRecognition()
                // Teams calls use separate windows. Only the known main shell is excluded;
                // unfamiliar windows retain full discovery. Audit mode verifies this layout
                // assumption with a full scan and never enables the early exit.
                let canExcludeMainWindow = excludeMainWindows && !auditMainWindows &&
                    (control == .microphone || control == .camera)
                var windowComplete = true
                var windowVisitedNodes = 0
                var controls: [ControlSnapshot] = []
                var windowHandles = CallWindowHandles(application: app.application, window: window)
                var queue: [(AXUIElement, Int, Int)] = []
                if scheduled.count < maxNodes && scheduled.insert(window).inserted {
                    queue.append((window, 0, 0))
                } else {
                    windowComplete = false
                    scanTimings?.markIncomplete()
                }
                var cursor = 0
                while cursor < queue.count {
                    guard visited.count < maxNodes, environment.uptime() < deadline else {
                        windowComplete = false
                        scanTimings?.markIncomplete()
                        break
                    }
                    let (node, depth, branch) = queue[cursor]
                    cursor += 1
                    guard visited.insert(node).inserted else { continue }
                    timings?.increment("visited_nodes")
                    windowVisitedNodes += 1
                    scanTimings?.visit(branch: branch, depth: depth)
                    environment.setMessagingTimeout(node, 0.25)
                    let fields = attributes(node, [kAXRoleAttribute, kAXChildrenAttribute],
                                            group: "node_attributes", scanTimings: scanTimings, branch: branch)
                    if fields.failed {
                        windowComplete = false
                        scanTimings?.markIncomplete()
                    }
                    let role = fields.values[0] as? String ?? ""
                    scanTimings?.recordRole(role, branch: branch)
                    if role.isEmpty {
                        windowComplete = false
                        scanTimings?.markIncomplete()
                    }
                    // Bound classification work to the shell prefix. Missing markers, errors,
                    // and call evidence fall back to the same traversal without restarting it.
                    let probeMainWindow = auditMainWindows || (canExcludeMainWindow && windowComplete &&
                        windowVisitedNodes <= mainWindowNodeLimit && depth <= mainWindowDepthLimit &&
                        !mainWindowRecognition.hasCallControls)
                    if probeMainWindow && role == "AXComboBox" {
                        let identity = attributes(node, ["AXDOMIdentifier", kAXIdentifierAttribute],
                                                  group: "main_window_identifiers", scanTimings: scanTimings, branch: branch)
                        mainWindowRecognition.observe(role: role, identifiers: identity.values.compactMap { $0 as? String },
                                                      complete: !identity.failed)
                    }
                    if control == .hand && role == "AXImage" {
                        let text = attributes(node, [kAXDescriptionAttribute], group: "image_labels",
                                              scanTimings: scanTimings, branch: branch)
                        if text.failed {
                            windowComplete = false
                            scanTimings?.markIncomplete()
                        }
                        let indicator = ControlSnapshot(role: role, identifier: "", label: text.values[0] as? String ?? "")
                        if OwnVideoHandIndicator.matches(indicator) {
                            controls.append(indicator)
                            windowHandles.ownVideos.append(node)
                        }
                    }
                    if role == "AXButton" {
                        let identity = attributes(node, ["AXDOMIdentifier", kAXIdentifierAttribute],
                                                  group: "button_identifiers", scanTimings: scanTimings, branch: branch)
                        if identity.failed {
                            windowComplete = false
                            scanTimings?.markIncomplete()
                        }
                        let identifiers = identity.values.compactMap { $0 as? String }
                        if auditMainWindows || canExcludeMainWindow {
                            mainWindowRecognition.observe(role: role, identifiers: identifiers, complete: !identity.failed)
                        }
                        if let identifier = identifiers.first(where: {
                            ["microphone-button", "video-button", "hangup-button", "resume-button"].contains($0) ||
                                (control == .hand && $0 == MediaControl.hand.rawValue)
                        }) {
                            let text = attributes(node, [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute],
                                                  group: "control_labels", scanTimings: scanTimings, branch: branch)
                            if text.failed {
                                windowComplete = false
                                scanTimings?.markIncomplete()
                            }
                            scanTimings?.recordControl(identifier, branch: branch)
                            let label = text.values.compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
                            controls.append(ControlSnapshot(role: role, identifier: identifier, label: label))
                            if identifier == "microphone-button" { windowHandles.microphones.append(node) }
                            if identifier == "video-button" { windowHandles.cameras.append(node) }
                            if identifier == "hangup-button" { windowHandles.hangups.append(node) }
                            if identifier == MediaControl.hand.rawValue { windowHandles.hands.append(node) }
                        }
                    }
                    if canExcludeMainWindow && probeMainWindow && windowComplete &&
                        mainWindowRecognition.result == .mainShell {
                        guard environment.uptime() < deadline else {
                            windowComplete = false
                            scanTimings?.markIncomplete()
                            break
                        }
                        // Discard only the unvisited queue belonging to this window. Its
                        // prefix still counts toward the scan budget; later windows are fresh.
                        for (pending, _, _) in queue[cursor...] { scheduled.remove(pending) }
                        timings?.increment("excluded_main_windows")
                        scanTimings?.excludeMainWindow()
                        break
                    }
                    let children = fields.values[1] as? [AXUIElement] ?? []
                    if depth >= maxDepth {
                        if !children.isEmpty {
                            windowComplete = false
                            scanTimings?.markIncomplete()
                        }
                    } else {
                        for child in children where !scheduled.contains(child) {
                            guard scheduled.count < maxNodes else {
                                windowComplete = false
                                scanTimings?.markIncomplete()
                                break
                            }
                            scheduled.insert(child)
                            let childBranch = scanTimings?.branchForChild(of: branch, depth: depth + 1,
                                                                          siblingCount: children.count) ?? 0
                            queue.append((child, depth + 1, childBranch))
                        }
                    }
                }
                complete = complete && windowComplete
                if auditMainWindows || canExcludeMainWindow {
                    scanTimings?.recordMainWindowRecognition(mainWindowRecognition)
                }
                snapshots.append(WindowSnapshot(index: snapshots.count + 1, controls: controls))
                handles[snapshots.count] = windowHandles
            }
        }
        scanTimings?.finish(complete: complete)
        return TeamsSnapshot(windows: snapshots, complete: complete, focusUnchanged: nil, handles: handles)
    }

    private func attributes(_ element: AXUIElement, _ names: [String], group: String,
                            scanTimings: AccessibilityDiscoveryTimings?, branch: Int) -> AttributeValues {
        timings?.increment("attribute_calls")
        timings?.increment("batch_attribute_calls")
        let (raw, error) = timings.measureAggregate(group, record: { duration in
            scanTimings?.recordRequest(group, durationMS: duration, branch: branch)
        }) { environment.copyAttributes(element, names) }
        guard error == .success, let array = raw as? [Any], array.count == names.count else {
            return AttributeValues(values: Array(repeating: nil, count: names.count), failed: true)
        }
        var failed = false
        let values: [Any?] = array.map { item in
            if CFGetTypeID(item as CFTypeRef) == AXValueGetTypeID() {
                let wrapped = item as! AXValue
                if AXValueGetType(wrapped) == .axError {
                    var code = AXError.success
                    AXValueGetValue(wrapped, .axError, &code)
                    // Absent optional attributes and leaf children are ordinary. Communication
                    // failures or inaccessible nodes make the overall result inconclusive.
                    if code != .attributeUnsupported && code != .noValue { failed = true }
                    return nil
                }
            }
            return item
        }
        return AttributeValues(values: values, failed: failed)
    }
}

private struct AttributeValues {
    let values: [Any?]
    let failed: Bool
}
