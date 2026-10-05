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

    func buttons(for control: MediaControl) -> [AXUIElement] {
        switch control {
        case .microphone: return microphones
        case .camera: return cameras
        }
    }
}

/// Reads controls only: no activation, events, AX actions, attribute writes, or permission prompts.
public final class TeamsAccessibilityReader {
    private let maxNodes = 12_000
    private let maxDepth = 80
    private let maxSeconds: TimeInterval = 8

    public init() {}

    public func read(control: MediaControl = .microphone, timeout: TimeInterval = 8) throws -> TeamsSnapshot {
        guard AXIsProcessTrusted() else { throw TeamsReadError.accessibilityDenied }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2")
        guard !apps.isEmpty else { throw TeamsReadError.notRunning }
        let focusBefore = FocusSnapshot.capture()
        let deadline = ProcessInfo.processInfo.systemUptime + min(maxSeconds, max(0, timeout))

        // Chromium enables its native accessibility tree when the browser app's role is read.
        // Teams' web content is hosted by this background helper, not its main application.
        // Helpers can share a bundle ID; query only the browser executable, not renderers/utilities.
        for helper in NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2.helper") {
            guard helper.executableURL?.lastPathComponent == "Microsoft Teams WebView" else { continue }
            let element = AXUIElementCreateApplication(helper.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            _ = attribute(element, kAXRoleAttribute)
        }

        var result = try scan(apps, deadline: deadline)
        // The web tree can appear asynchronously after the role query. Retry once without
        // changing focus or enabling screen-reader mode. The scan itself is bounded.
        if ProcessInfo.processInfo.systemUptime + 0.25 < deadline && result.complete && !result.windows.contains(where: { window in
            window.controls.contains(where: { $0.identifier == control.rawValue })
        }) {
            Thread.sleep(forTimeInterval: 0.25)
            result = try scan(apps, deadline: deadline)
        }
        return TeamsSnapshot(windows: result.windows, complete: result.complete,
                             focusUnchanged: focusBefore.matches(FocusSnapshot.capture()), handles: result.handles)
    }

    private func scan(_ apps: [NSRunningApplication], deadline: TimeInterval) throws -> TeamsSnapshot {
        var visited = Set<AXUIElement>()
        var scheduled = Set<AXUIElement>()
        var complete = true
        var snapshots: [WindowSnapshot] = []
        var handles: [Int: CallWindowHandles] = [:]

        for app in apps {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.25)
            let (rawWindows, error) = attribute(root, kAXWindowsAttribute)
            guard error == .success, let windows = rawWindows as? [AXUIElement] else {
                throw TeamsReadError.accessibilityFailure(error.rawValue)
            }
            for window in windows {
                var controls: [ControlSnapshot] = []
                var windowHandles = CallWindowHandles(application: app, window: window)
                var queue: [(AXUIElement, Int)] = []
                if scheduled.count < maxNodes && scheduled.insert(window).inserted {
                    queue.append((window, 0))
                } else { complete = false }
                var cursor = 0
                while cursor < queue.count {
                    guard visited.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline else {
                        complete = false
                        break
                    }
                    let (node, depth) = queue[cursor]
                    cursor += 1
                    guard visited.insert(node).inserted else { continue }
                    AXUIElementSetMessagingTimeout(node, 0.25)
                    let fields = attributes(node, [kAXRoleAttribute, kAXChildrenAttribute])
                    if fields.failed { complete = false }
                    let role = fields.values[0] as? String ?? ""
                    if role.isEmpty { complete = false }
                    if role == "AXButton" {
                        let identity = attributes(node, ["AXDOMIdentifier", kAXIdentifierAttribute])
                        if identity.failed { complete = false }
                        let identifiers = identity.values.compactMap { $0 as? String }
                        if let identifier = identifiers.first(where: { ["microphone-button", "video-button", "hangup-button", "resume-button"].contains($0) }) {
                            let text = attributes(node, [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute])
                            if text.failed { complete = false }
                            let label = text.values.compactMap { $0 as? String }.first(where: { !$0.isEmpty }) ?? ""
                            controls.append(ControlSnapshot(role: role, identifier: identifier, label: label))
                            if identifier == "microphone-button" { windowHandles.microphones.append(node) }
                            if identifier == "video-button" { windowHandles.cameras.append(node) }
                            if identifier == "hangup-button" { windowHandles.hangups.append(node) }
                        }
                    }
                    let children = fields.values[1] as? [AXUIElement] ?? []
                    if depth >= maxDepth {
                        if !children.isEmpty { complete = false }
                    } else {
                        for child in children where !scheduled.contains(child) {
                            guard scheduled.count < maxNodes else {
                                complete = false
                                break
                            }
                            scheduled.insert(child)
                            queue.append((child, depth + 1))
                        }
                    }
                }
                snapshots.append(WindowSnapshot(index: snapshots.count + 1, controls: controls))
                handles[snapshots.count] = windowHandles
            }
        }
        return TeamsSnapshot(windows: snapshots, complete: complete, focusUnchanged: nil, handles: handles)
    }
}

private func attribute(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, error)
}

private struct AttributeValues {
    let values: [Any?]
    let failed: Bool
}

private func attributes(_ element: AXUIElement, _ names: [String]) -> AttributeValues {
    var raw: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
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

private struct FocusSnapshot {
    let pid: pid_t?
    let window: AXUIElement?

    static func capture() -> FocusSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FocusSnapshot(pid: nil, window: nil)
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        let (raw, _) = attribute(root, kAXFocusedWindowAttribute)
        let window: AXUIElement? = raw.flatMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
        return FocusSnapshot(pid: app.processIdentifier, window: window)
    }

    func matches(_ other: FocusSnapshot) -> Bool? {
        guard let pid, let otherPID = other.pid else { return nil }
        guard pid == otherPID else { return false }
        guard let window, let otherWindow = other.window else { return nil }
        return CFEqual(window, otherWindow)
    }
}
