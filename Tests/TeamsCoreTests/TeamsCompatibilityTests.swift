import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class TeamsCompatibilityTests: XCTestCase {
    func testCompleteCallPassesAndReportDoesNotContainPrivateLabels() throws {
        let stub = healthyTree()
        let report = probe(stub).run(metadata: ["teams_language": "en"])
        XCTAssertEqual(report.outcome, .pass)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(check(report, "mic_state").state, "unmuted")
        XCTAssertEqual(check(report, "camera_state").state, "off")
        XCTAssertEqual(check(report, "hand_state").state, "lowered")
        XCTAssertEqual(check(report, "call_state").state, "active")
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for privateText in ["Private Person", "Private meeting", "Myself video", "Mute mic", "AXDescription"] {
            XCTAssertFalse(json.contains(privateText), privateText)
        }
        XCTAssertNoThrow(try report.validateBaseline())
    }

    func testNoCallHeldCallsAndMultipleCallsAreInconclusiveAndNeverInspectCapabilities() {
        for scenario in ["none", "held", "multiple", "incomplete"] {
            let stub = healthyTree()
            if scenario == "none" { stub.values[stub.root]?[kAXWindowsAttribute] = [] as [AXUIElement] }
            if scenario == "held" {
                let window = callWindow(stub)
                var children = stub.values[window]?[kAXChildrenAttribute] as! [AXUIElement]
                children.append(stub.button("resume-button", label: "Resume"))
                stub.values[window]?[kAXChildrenAttribute] = children
            }
            if scenario == "multiple" { stub.window([stub.button("hangup-button", label: "Leave")]) }
            if scenario == "incomplete" {
                let window = callWindow(stub)
                stub.values[window]?[kAXChildrenAttribute] = readerAXError(.cannotComplete)
            }
            var subject = probe(stub)
            subject.capabilities = { _ in XCTFail("No capability reads for \(scenario)"); return .init(outcome: .pass, reason: "unexpected") }
            let report = subject.run(metadata: [:])
            XCTAssertEqual(report.outcome, .inconclusive, scenario)
            XCTAssertEqual(report.exitCode, 2, scenario)
            XCTAssertEqual(check(report, "mic_state").outcome, .inconclusive, scenario)
            XCTAssertThrowsError(try report.validateBaseline(), scenario)
        }
    }

    func testDeniedPermissionOrUnavailableProcessStopsBeforeDiscovery() {
        for scenario in ["denied", "absent", "multiple"] {
            let stub = healthyTree()
            if scenario == "denied" { stub.trusted = false }
            if scenario == "absent" { stub.applications = [] }
            if scenario == "multiple" { stub.applications += stub.applications }
            let report = probe(stub).run(metadata: [:])
            XCTAssertEqual(report.outcome, .inconclusive)
            XCTAssertTrue(stub.batchReads.isEmpty)
        }
    }

    func testMissingRenamedDuplicateAndUnrecognizedControlsFail() {
        for scenario in ["missing", "renamed", "duplicate", "label", "leave_label", "hand_label"] {
            let stub = healthyTree()
            let window = callWindow(stub)
            var children = stub.values[window]?[kAXChildrenAttribute] as! [AXUIElement]
            if scenario == "missing" { children.removeFirst() }
            if scenario == "renamed" { stub.values[children[0]]?["AXDOMIdentifier"] = "new-microphone-id" }
            if scenario == "duplicate" { children.append(stub.button()) }
            if scenario == "label" { stub.values[children[0]]?[kAXDescriptionAttribute] = "new microphone label" }
            if scenario == "leave_label" { stub.values[children[3]]?[kAXDescriptionAttribute] = "new leave label" }
            if scenario == "hand_label" {
                stub.values[children[4]]?[kAXDescriptionAttribute] = "Myself video, Private Person, video is off, hand uncertain, has context menu"
            }
            stub.values[window]?[kAXChildrenAttribute] = children
            let report = probe(stub).run(metadata: [:])
            XCTAssertEqual(report.outcome, .fail, scenario)
            XCTAssertEqual(report.exitCode, 1, scenario)
        }
    }

    func testMissingOwnVideoAndMainShellCannotQualify() {
        for scenario in ["tile", "shell"] {
            let stub = healthyTree()
            if scenario == "tile" {
                let window = callWindow(stub)
                var children = stub.values[window]?[kAXChildrenAttribute] as! [AXUIElement]
                children.removeLast()
                stub.values[window]?[kAXChildrenAttribute] = children
            } else {
                let window = callWindow(stub)
                stub.values[stub.root]?[kAXWindowsAttribute] = [window]
            }
            let report = probe(stub).run(metadata: [:])
            XCTAssertEqual(report.outcome, .inconclusive, scenario)
        }
    }

    func testFullAuditFindsCallControlsDeepInsideRecognizedMainWindow() {
        let stub = healthyTree()
        let windows = stub.values[stub.root]?[kAXWindowsAttribute] as! [AXUIElement]
        var deep = stub.button("video-button", label: "Turn camera on")
        for _ in 0..<30 { deep = stub.node(children: [deep]) }
        var children = stub.values[windows[0]]?[kAXChildrenAttribute] as! [AXUIElement]
        children.append(deep)
        stub.values[windows[0]]?[kAXChildrenAttribute] = children
        let report = probe(stub).run(metadata: [:])
        XCTAssertEqual(check(report, "main_window_layout").reason, "main_shell_contains_call_controls")
        XCTAssertEqual(report.outcome, .fail)
        XCTAssertTrue(stub.traversed.contains(deep))
    }

    func testFocusChangeOrMissingFocusIsInconclusive() {
        for focus in [ReaderFocusSnapshot(pid: 2, window: AXUIElementCreateApplication(55)),
                      ReaderFocusSnapshot(pid: nil, window: nil)] {
            let stub = healthyTree()
            stub.focusSnapshots = [ReaderFocusSnapshot(pid: 1, window: stub.focusWindow), focus]
            let report = probe(stub).run(metadata: [:])
            XCTAssertEqual(check(report, "focus_endpoints").outcome, .inconclusive)
            XCTAssertEqual(report.outcome, .inconclusive)
        }
    }

    func testRestartInvalidatesEvenFailingEvidence() {
        let stub = healthyTree()
        var subject = probe(stub)
        var identities = 0
        subject.processIdentity = { _ in
            identities += 1
            return MediaProcessGeneration(pid: 42, launched: Date(timeIntervalSince1970: Double(identities)))
        }
        subject.capabilities = { _ in .init(outcome: .fail, reason: "control_missing") }
        let report = subject.run(metadata: [:])
        XCTAssertEqual(report.outcome, .inconclusive)
        XCTAssertEqual(check(report, "mic_press").reason, "process_changed_or_unavailable")
    }

    func testDiscoveryErrorProducesAReport() {
        let stub = healthyTree()
        stub.singleErrors[stub.root] = .cannotComplete
        let report = probe(stub).run(metadata: [:])
        XCTAssertEqual(report.outcome, .inconclusive)
        XCTAssertEqual(check(report, "inspection").outcome, .inconclusive)
    }

    func testCapabilityReadSeparatesDisabledUnadvertisedAndUnavailable() {
        let element = AXUIElementCreateApplication(42)
        for scenario in ["ready", "disabled", "empty_actions", "other_actions", "enabled_error", "actions_error", "malformed"] {
            let environment = MediaAccessibilityEnvironment(
                runningApplication: { _ in nil }, isTerminated: { _ in false }, launchDate: { _ in nil },
                setMessagingTimeout: { _, timeout in XCTAssertEqual(timeout, 0.25) },
                copyAttribute: { _, name in
                    XCTAssertEqual(name, kAXEnabledAttribute)
                    if scenario == "enabled_error" { return (kCFBooleanTrue, .cannotComplete) }
                    if scenario == "malformed" { return ("enabled" as CFString, .success) }
                    return (scenario == "disabled" ? kCFBooleanFalse : kCFBooleanTrue, .success)
                }, copyActionNames: { _ in
                    if scenario == "actions_error" { return ([kAXPressAction] as CFArray, .cannotComplete) }
                    if scenario == "empty_actions" { return ([] as CFArray, .success) }
                    if scenario == "other_actions" { return (["AXShowMenu"] as CFArray, .success) }
                    return ([kAXPressAction] as CFArray, .success)
                })
            let actual = CompatibilityCapability.read(element, environment: environment)
            var expected: CompatibilityVerdict = .inconclusive
            if scenario == "ready" { expected = .pass }
            XCTAssertEqual(actual.outcome, expected, scenario)
            if scenario == "empty_actions" || scenario == "other_actions" {
                XCTAssertEqual(actual.reason, "axpress_not_advertised_read_only")
            }
        }
    }

    func testRecognizedStatesWithoutAdvertisedPressAreInconclusiveAndCannotBecomeBaseline() {
        for enhanced in [false, true] {
            let stub = healthyTree()
            stub.values[stub.root]?["AXEnhancedUserInterface"] = enhanced
            let native = MediaAccessibilityEnvironment(
                runningApplication: { _ in nil }, isTerminated: { _ in false }, launchDate: { _ in nil },
                setMessagingTimeout: { _, _ in }, copyAttribute: { _, _ in (kCFBooleanTrue, .success) },
                copyActionNames: { _ in ([] as CFArray, .success) })
            var subject = probe(stub)
            subject.capabilities = { CompatibilityCapability.read($0, environment: native) }
            let report = subject.run(metadata: [:])
            XCTAssertEqual(report.outcome, .inconclusive)
            XCTAssertEqual(report.exitCode, 2)
            for name in ["mic", "camera", "hand", "call"] {
                XCTAssertEqual(check(report, name + "_state").outcome, .pass)
                XCTAssertEqual(check(report, name + "_press").outcome, .inconclusive)
                XCTAssertEqual(check(report, name + "_press").reason, "axpress_not_advertised_read_only")
            }
            XCTAssertEqual(report.metadata["enhanced_accessibility_before_scan"], String(enhanced))
            XCTAssertEqual(report.metadata["enhanced_accessibility_after_probe"], String(enhanced))
            XCTAssertEqual(stub.values[stub.root]?["AXEnhancedUserInterface"] as? Bool, enhanced)
            XCTAssertThrowsError(try report.validateBaseline())
        }
    }

    func testEnhancedAccessibilityMetadataRecordsExternalChangesWithoutChangingTheAttribute() {
        let stub = healthyTree()
        stub.values[stub.root]?["AXEnhancedUserInterface"] = false
        stub.onBatchRead = { _, _ in stub.values[stub.root]?["AXEnhancedUserInterface"] = true }
        let report = probe(stub).run(metadata: [:])
        XCTAssertEqual(report.outcome, .pass)
        XCTAssertEqual(report.metadata["enhanced_accessibility_before_scan"], "false")
        XCTAssertEqual(report.metadata["enhanced_accessibility_after_probe"], "true")
        XCTAssertEqual(stub.values[stub.root]?["AXEnhancedUserInterface"] as? Bool, true)
    }

    func testEnhancedAccessibilityMetadataDoesNotGuessMissingOrMalformedValues() {
        for value: Any? in [nil, "false", 0] {
            let stub = healthyTree()
            stub.values[stub.root]?["AXEnhancedUserInterface"] = value
            let report = probe(stub).run(metadata: [:])
            XCTAssertEqual(report.outcome, .pass)
            XCTAssertEqual(report.metadata["enhanced_accessibility_before_scan"], "unavailable")
            XCTAssertEqual(report.metadata["enhanced_accessibility_after_probe"], "unavailable")
        }
    }

    func testBaselineComparisonIgnoresNormalStateChangesButReportsRegressionsAndMetadata() throws {
        let baseline = passingReport(scanMS: 100)
        var checks = baseline.checks
        checks[5] = CompatibilityCheck(id: "mic_state", outcome: .pass, reason: "recognized", state: "muted")
        var current = TeamsCompatibilityReport(metadata: ["teams_build": "new"], checks: checks, scanMS: 400, elapsedMS: 450)
        let comparison = try current.comparing(to: baseline)
        XCTAssertTrue(comparison.checks.isEmpty)
        XCTAssertEqual(comparison.metadata.first?.field, "teams_build")
        XCTAssertTrue(comparison.slowdown)
        XCTAssertEqual(comparison.scanRatio, 4)
        checks[5] = CompatibilityCheck(id: "mic_state", outcome: .fail, reason: "unrecognized_microphone_label")
        current = TeamsCompatibilityReport(metadata: [:], checks: checks, scanMS: 200, elapsedMS: 250)
        XCTAssertEqual(try current.comparing(to: baseline).checks.map(\.id), ["mic_state"])
        XCTAssertFalse(try current.comparing(to: baseline).slowdown)
        XCTAssertNil(try current.comparing(to: passingReport(scanMS: 0)).scanRatio)
    }

    func testBaselineValidationRejectsWrongSchemaScopeAndIncompleteOrForgedPass() throws {
        let data = try JSONEncoder().encode(passingReport(scanMS: 100))
        for scenario in ["schema", "scope", "empty", "duplicate", "failed", "negative_timing"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var checks = object["checks"] as! [[String: Any]]
            switch scenario {
            case "schema": object["schema_version"] = 2
            case "scope": object["scope"] = "actions"
            case "empty": checks = []
            case "duplicate": checks[1] = checks[0]
            case "failed": checks[0]["outcome"] = "FAIL"
            default: object["scan_ms"] = -1
            }
            object["checks"] = checks
            let report = try JSONDecoder().decode(TeamsCompatibilityReport.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try report.validateBaseline(), scenario)
        }
    }

    private func passingReport(scanMS: Double) -> TeamsCompatibilityReport {
        TeamsCompatibilityReport(metadata: ["teams_build": "old"], checks: TeamsCompatibilityReport.checkIDs.map {
            CompatibilityCheck(id: $0, outcome: .pass, reason: "recognized", state: $0 == "mic_state" ? "unmuted" : nil)
        }, scanMS: scanMS, elapsedMS: scanMS)
    }

    private func check(_ report: TeamsCompatibilityReport, _ id: String) -> CompatibilityCheck {
        report.checks.first { $0.id == id }!
    }

    private func probe(_ stub: AccessibilityReaderStub) -> TeamsCompatibilityProbe {
        TeamsCompatibilityProbe(readerEnvironment: stub.environment,
                                capabilities: { _ in .init(outcome: .pass, reason: "enabled_and_axpress_available") },
                                processIdentity: { _ in MediaProcessGeneration(pid: 42, launched: Date(timeIntervalSince1970: 100)) })
    }

    private func callWindow(_ stub: AccessibilityReaderStub) -> AXUIElement {
        (stub.values[stub.root]?[kAXWindowsAttribute] as! [AXUIElement])[1]
    }

    private func healthyTree() -> AccessibilityReaderStub {
        let stub = AccessibilityReaderStub()
        stub.window([stub.button("idna-me-control-avatar-trigger"),
                     stub.node("AXComboBox", attributes: ["AXDOMIdentifier": "ms-searchux-input"])])
        let window = stub.window([stub.button(), stub.button("video-button", label: "Turn camera on"),
                                  stub.button("raisehands-button", label: "Raise hand"),
                                  stub.button("hangup-button", label: "Leave"),
                                  stub.node("AXImage", attributes: [kAXDescriptionAttribute:
                                    "Myself video, Private Person, video is off, has context menu"])])
        stub.values[window]?[kAXTitleAttribute] = "Private meeting"
        return stub
    }
}
