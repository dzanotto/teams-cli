import AppKit
import ApplicationServices
@testable import TeamsCore

/// AX elements are identity tokens only; every read goes through this in-memory tree.
final class AccessibilityReaderStub {
    let root = AXUIElementCreateApplication(10)
    let focusWindow = AXUIElementCreateApplication(11)
    var trusted = true
    var applications: [AccessibilityReaderApplication] = []
    var helpers: [AccessibilityReaderApplication] = []
    var values: [AXUIElement: [String: Any]] = [:]
    var singleErrors: [AXUIElement: AXError] = [:]
    var batchOverride: ((AXUIElement, [String]) -> (CFArray?, AXError)?)?
    var onBatchRead: ((AXUIElement, [String]) -> Void)?
    var onSleep: (() -> Void)?
    var focusSnapshots: [ReaderFocusSnapshot] = []
    var now: TimeInterval = 100
    private var nextID: pid_t = 100
    private(set) var bundleQueries: [String] = []
    private(set) var singleReads: [(element: AXUIElement, name: String)] = []
    private(set) var batchReads: [(element: AXUIElement, names: [String])] = []
    private(set) var messagingTimeouts: [(element: AXUIElement, seconds: Float)] = []
    private(set) var sleeps: [TimeInterval] = []
    private(set) var focusCaptureCount = 0
    private(set) var events: [String] = []

    init() {
        applications = [application(root)]
        values[root] = [kAXWindowsAttribute: [AXUIElement]()]
    }

    func application(_ element: AXUIElement, executable: String? = nil) -> AccessibilityReaderApplication {
        AccessibilityReaderApplication(application: NSRunningApplication.current, element: element,
                                       executableName: executable)
    }

    func node(_ role: String = "AXGroup", attributes: [String: Any] = [:],
              children: [AXUIElement] = []) -> AXUIElement {
        let element = AXUIElementCreateApplication(nextID)
        nextID += 1
        values[element] = [kAXRoleAttribute: role, kAXChildrenAttribute: children]
            .merging(attributes) { _, new in new }
        return element
    }

    func button(_ identifier: String = "microphone-button", label: String = "Mute mic") -> AXUIElement {
        node("AXButton", attributes: ["AXDOMIdentifier": identifier, kAXDescriptionAttribute: label])
    }

    @discardableResult
    func window(_ children: [AXUIElement] = []) -> AXUIElement {
        let window = node("AXWindow", children: children)
        var windows = values[root]?[kAXWindowsAttribute] as? [AXUIElement] ?? []
        windows.append(window)
        values[root]?[kAXWindowsAttribute] = windows
        return window
    }

    func read(control: MediaControl = .microphone, timeout: TimeInterval = 8) throws -> TeamsSnapshot {
        try TeamsAccessibilityReader(environment: environment).read(control: control, timeout: timeout)
    }

    var traversed: [AXUIElement] {
        batchReads.filter { $0.names == [kAXRoleAttribute, kAXChildrenAttribute] }.map(\.element)
    }

    var windowReadCount: Int { singleReads.filter { $0.name == kAXWindowsAttribute }.count }

    var environment: AccessibilityReaderEnvironment {
        AccessibilityReaderEnvironment(isTrusted: {
            self.events.append("permission")
            return self.trusted
        }, runningApplications: { bundleID in
            self.bundleQueries.append(bundleID)
            self.events.append(bundleID)
            return bundleID == "com.microsoft.teams2" ? self.applications : self.helpers
        }, setMessagingTimeout: { element, seconds in
            self.messagingTimeouts.append((element, seconds))
        }, copyAttribute: { element, name in
            self.singleReads.append((element, name))
            self.events.append(name)
            if let error = self.singleErrors[element] { return (nil, error) }
            guard let value = self.values[element]?[name] else { return (nil, .noValue) }
            return (value as CFTypeRef, .success)
        }, copyAttributes: { element, names in
            self.batchReads.append((element, names))
            self.events.append("batch")
            self.onBatchRead?(element, names)
            if let override = self.batchOverride?(element, names) { return override }
            let result = names.map { self.values[element]?[$0] ?? readerAXError(.attributeUnsupported) }
            return (result as CFArray, .success)
        }, captureFocus: {
            self.focusCaptureCount += 1
            self.events.append("focus")
            if !self.focusSnapshots.isEmpty { return self.focusSnapshots.removeFirst() }
            return ReaderFocusSnapshot(pid: 1, window: self.focusWindow)
        }, uptime: { self.now }, sleep: { seconds in
            self.sleeps.append(seconds)
            self.now += seconds
            self.onSleep?()
        })
    }
}

func readerAXError(_ error: AXError) -> AXValue {
    var error = error
    return AXValueCreate(.axError, &error)!
}
