import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class AccessibilityCallEndBackendTests: XCTestCase {
    func testControllerPressesPinnedButtonOnceAndConfirmsTwoNativeClosureObservations() throws {
        let client = CallEndAccessibilityStub([call(), call(), call(), closed(), closed()])
        let result = try CallEndController(backend: backend(client)).end()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .ended)
        XCTAssertEqual(result.changed, true)
        XCTAssertTrue(result.actionAttempted)
        XCTAssertNil(result.reason)
        XCTAssertEqual(client.pressedElements.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(client.pressedElements.first), AXUIElementCreateApplication(11)))
        // Call end retains its full discovery recheck immediately before dispatch.
        XCTAssertEqual(client.readCountAtPress, 3)
        XCTAssertEqual(client.readCount, 5)
        XCTAssertEqual(client.waitCount, 2)
        XCTAssertEqual(client.controls, Array(repeating: .call, count: 5))
    }

    func testWindowReorderingPreservesPinnedTargetAndSameCallEvidence() throws {
        let client = CallEndAccessibilityStub([call(), call(index: 4)])
        let native = backend(client)
        let first = try native.sample()
        XCTAssertEqual(try native.sample().targetID, first.targetID)
        let verification = try native.verify(targetID: XCTUnwrap(first.targetID))
        XCTAssertEqual(verification.presence, .sameCall)
        XCTAssertEqual(verification.assessment.windows.map(\.window), [4])
    }

    func testMissingHandlesAndInvalidSelectionsCannotEstablishTarget() throws {
        var missingHandles = call()
        missingHandles.handles = [:]
        var missingButton = call()
        missingButton.handles[1]?.hangups = []
        var duplicateHandles = call()
        duplicateHandles.handles[1]?.hangups.append(AXUIElementCreateApplication(12))
        for snapshot in [missingHandles, missingButton, duplicateHandles, empty(), closed(),
                         call(held: true), call(complete: false), call(label: "End meeting for all"),
                         call(buttons: [11, 12]), combining(call(), call(index: 2, window: 20))] {
            let client = CallEndAccessibilityStub([snapshot])
            let observation = try backend(client).sample()
            XCTAssertNil(observation.targetID)
            XCTAssertFalse(observation.canPress)
            XCTAssertTrue(client.pressedElements.isEmpty)
        }
    }

    func testUnavailableGenerationOrStoppedProcessCannotEstablishUsableTarget() throws {
        for missingGeneration in [true, false] {
            let client = CallEndAccessibilityStub([call()])
            if missingGeneration { client.windowGeneration = nil }
            else { client.runningGeneration = nil }
            let observation = try backend(client).sample()
            XCTAssertNil(observation.targetID)
            XCTAssertFalse(observation.canPress)
        }
    }

    func testReplacementWindowButtonOrProcessCannotInheritPinnedTarget() throws {
        for replacement in ["window", "button", "pid", "launch"] {
            let client = CallEndAccessibilityStub([call()])
            let native = backend(client)
            let original = try XCTUnwrap(native.sample().targetID)
            if replacement == "window" { client.snapshots = [call(window: 20)] }
            if replacement == "button" { client.snapshots = [call(buttons: [12])] }
            if replacement == "pid" { client.windowGeneration = generation(pid: 456) }
            if replacement == "launch" { client.windowGeneration = generation(launch: 2) }
            if replacement == "pid" || replacement == "launch" {
                client.runningGeneration = client.windowGeneration
            }
            XCTAssertNil(try native.sample().targetID)
            // Repeated samples must not silently repin this command to the replacement.
            XCTAssertNil(try native.sample().targetID)
            assertRejected("target_changed") { try native.press(targetID: original) }
            XCTAssertTrue(client.pressedElements.isEmpty)
        }
    }

    func testFreshDispatchScanRejectsChangedCallEligibility() throws {
        let cases: [(TeamsSnapshot, String)] = [
            (call(held: true), "all_calls_on_hold"),
            (call(complete: false), "inspection_incomplete"),
            (closed(), "no_call_controls"),
            (combining(call(), call(index: 2, window: 20)), "multiple_call_windows"),
            (call(buttons: [11, 12]), "multiple_hangup_controls"),
            (call(label: "End meeting for all"), "unrecognized_hangup_label")
        ]
        for (snapshot, reason) in cases {
            let client = CallEndAccessibilityStub([call(), call(), snapshot])
            let result = try CallEndController(backend: backend(client)).end()
            assertRefused(result, reason: reason)
            XCTAssertEqual(client.readCount, 3)
            XCTAssertTrue(client.pressedElements.isEmpty)
            XCTAssertEqual(client.waitCount, 0)
        }
    }

    func testDirectButtonReadRejectsChangedRoleIdentifierAndLeaveLabel() throws {
        let changes = [
            ["AXRole": "AXStaticText"], ["AXDOMIdentifier": "end-for-everyone"],
            ["AXDescription": "End meeting for all"], ["AXDescription": ""]
        ]
        for change in changes {
            let client = CallEndAccessibilityStub([call()])
            client.attributes.merge(change) { _, new in new }
            assertRefused(try CallEndController(backend: backend(client)).end(), reason: "unrecognized_hangup_label")
            XCTAssertTrue(client.pressedElements.isEmpty)
        }
    }

    func testDirectReadAcceptsSupportedFallbackIdentifierAndLabel() throws {
        for labelAttribute in [kAXTitleAttribute, kAXHelpAttribute] {
            let client = CallEndAccessibilityStub([call(), call(), call(), closed()])
            client.attributes = [kAXRoleAttribute: "AXButton", kAXIdentifierAttribute: "hangup-button",
                                 labelAttribute: "Leave (⌘⇧H)"]
            XCTAssertTrue(try CallEndController(backend: backend(client)).end().success)
            XCTAssertEqual(client.pressedElements.count, 1)
        }
    }

    func testDisabledControlAtDispatchDiscoveryOrFinalReadCannotBePressed() throws {
        for disabledCheck in [2, 3] {
            let client = CallEndAccessibilityStub([call()])
            client.onCanPress = { index in index != disabledCheck }
            assertRefused(try CallEndController(backend: backend(client)).end(), reason: "control_unavailable")
            XCTAssertTrue(client.pressedElements.isEmpty)
        }
    }

    func testProcessReplacementDuringDispatchRechecksPreventsPress() throws {
        for stage in ["scan", "after scan", "direct read"] {
            let client = CallEndAccessibilityStub([call()])
            if stage == "scan" {
                client.onRead = { [weak client] index in
                    if index == 3 { client?.runningGeneration = nil }
                }
            } else if stage == "after scan" {
                client.onCanPress = { [weak client] index in
                    if index == 2 { client?.runningGeneration = nil }
                    return true
                }
            } else {
                client.onValueRead = { [weak client] in client?.runningGeneration = nil }
            }
            assertRefused(try CallEndController(backend: backend(client)).end(), reason: "target_changed")
            XCTAssertTrue(client.pressedElements.isEmpty)
        }
    }

    func testUnknownTargetIDCannotDispatchOrVerify() throws {
        let client = CallEndAccessibilityStub([call()])
        let native = backend(client)
        XCTAssertEqual(try native.verify(targetID: "missing").presence, .changed)
        _ = try native.sample()
        XCTAssertEqual(try native.verify(targetID: "wrong").presence, .changed)
        assertRejected("target_changed") { try native.press(targetID: "wrong") }
        XCTAssertTrue(client.pressedElements.isEmpty)
    }

    func testReadFailuresBeforeDispatchNeverPress() throws {
        for failedRead in 1...3 {
            let client = CallEndAccessibilityStub([call()])
            client.failedRead = failedRead
            let controller = CallEndController(backend: backend(client))
            if failedRead < 3 {
                XCTAssertThrowsError(try controller.end()) { error in
                    guard case TeamsReadError.accessibilityFailure(-25204) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
            } else {
                assertRefused(try controller.end(), reason: "preflight_failed")
            }
            XCTAssertTrue(client.pressedElements.isEmpty)
            XCTAssertEqual(client.readCount, failedRead)
        }
    }

    func testNativePressErrorRemainsUncertainAndIsNeverRetried() throws {
        let client = CallEndAccessibilityStub([call()])
        client.pressError = .cannotComplete
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "action_outcome_unknown")
        XCTAssertEqual(client.pressedElements.count, 1)
        XCTAssertEqual(client.readCount, 3)
        XCTAssertEqual(client.waitCount, 0)
    }

    func testFocusChangesAndUnavailableFocusAreAllowedAndReported() throws {
        for focus: Bool? in [false, nil] {
            let client = CallEndAccessibilityStub([call(), call(), call(), closed()])
            client.focus = focus
            let result = try CallEndController(backend: backend(client)).end()
            XCTAssertTrue(result.success)
            XCTAssertEqual(result.focusUnchanged, focus)
            XCTAssertEqual(client.pressedElements.count, 1)
        }
    }

    func testMissingControlsOrEmptyWindowListNeverProveClosure() throws {
        for snapshot in [call(buttons: []), empty()] {
            let client = CallEndAccessibilityStub([call(), call(), call(), snapshot])
            assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "verification_timeout")
            XCTAssertEqual(client.waitCount, 20)
            XCTAssertEqual(client.pressedElements.count, 1)
        }
    }

    func testSurvivingWindowMustBelongToPinnedProcessGeneration() throws {
        for windowGeneration in [generation(pid: 456), generation(launch: 2), nil] {
            let client = CallEndAccessibilityStub([call(), closed()])
            let native = backend(client)
            let target = try XCTUnwrap(native.sample().targetID)
            // The pinned process is still alive, but the survivor is not proven to belong to it.
            client.windowGeneration = windowGeneration
            let verification = try native.verify(targetID: target)
            XCTAssertEqual(verification.presence, .unconfirmed)
            XCTAssertEqual(verification.assessment.reason, "no_call_controls")
        }
    }

    func testStoppedReplacedOrUnverifiableProcessCannotConfirmClosure() throws {
        for runningGeneration in [generation(pid: 456), generation(launch: 2), nil] {
            let client = CallEndAccessibilityStub([call(), call(), call(), closed()])
            client.onRead = { [weak client] index in
                if index == 4 { client?.runningGeneration = runningGeneration }
            }
            assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "target_changed")
            XCTAssertEqual(client.pressedElements.count, 1)
            XCTAssertEqual(client.waitCount, 1)
        }
    }

    func testReplacementOrDuplicateLeaveButtonCannotConfirmOriginalCall() throws {
        for buttons: [pid_t] in [[12], [11, 12]] {
            let client = CallEndAccessibilityStub([call(), call(), call(), call(buttons: buttons)])
            assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "target_changed")
            XCTAssertEqual(client.pressedElements.count, 1)
        }
    }

    func testAnotherActiveCallPreventsClosureConfirmation() throws {
        let client = CallEndAccessibilityStub([call(), call(), call(), call(window: 20, buttons: [21])])
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "target_changed")
        XCTAssertEqual(client.pressedElements.count, 1)
    }

    func testHeldSurvivorCanConfirmClosureButHeldOriginalCannot() throws {
        let held = call(index: 2, window: 20, buttons: [21], held: true)
        let before = combining(call(), held)
        let client = CallEndAccessibilityStub([before, before, before, held])
        let result = try CallEndController(backend: backend(client)).end()
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.state, .ended)
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
        XCTAssertEqual(client.pressedElements.count, 1)

        let original = CallEndAccessibilityStub([call(), call(), call(), call(held: true)])
        assertUncertain(try CallEndController(backend: backend(original)).end(), reason: "all_calls_on_hold")
        XCTAssertEqual(original.pressedElements.count, 1)
    }

    func testIncompleteScanCannotConfirmEvenApparentWindowClosure() throws {
        let client = CallEndAccessibilityStub([call(), call(), call(), call(window: 20, buttons: [], complete: false)])
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "inspection_incomplete")
        XCTAssertEqual(client.pressedElements.count, 1)
        XCTAssertEqual(client.waitCount, 1)
    }

    func testVerificationReadFailureLeavesAttemptUncertain() throws {
        let client = CallEndAccessibilityStub([call()])
        client.failedRead = 4
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "action_outcome_unknown")
        XCTAssertEqual(client.pressedElements.count, 1)
        XCTAssertEqual(client.waitCount, 1)
    }

    func testUnconfirmedNativeEvidenceResetsConsecutiveClosureRequirement() throws {
        let client = CallEndAccessibilityStub([call(), call(), call(), closed(), empty(), closed(), closed()])
        XCTAssertTrue(try CallEndController(backend: backend(client)).end().success)
        XCTAssertEqual(client.waitCount, 4)
        XCTAssertEqual(client.pressedElements.count, 1)
    }

    func testOneClosureAtVerificationLimitCannotConfirmSuccess() throws {
        let client = CallEndAccessibilityStub([call(), call(), call()] +
                                             Array(repeating: empty(), count: 19) + [closed()])
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "verification_timeout")
        XCTAssertEqual(client.waitCount, 20)
        XCTAssertEqual(client.pressedElements.count, 1)
    }

    func testReadsRespectRemainingBudgetAndExpiredBudgetPreventsFurtherReads() throws {
        let client = CallEndAccessibilityStub([call()])
        let native = backend(client)
        let target = try XCTUnwrap(native.sample().targetID)
        XCTAssertEqual(client.timeouts, [1.5])
        client.uptime = 7.9
        _ = try native.verify(targetID: target)
        XCTAssertEqual(try XCTUnwrap(client.timeouts.last), 0.1, accuracy: 0.000_001)
        client.uptime = 8
        XCTAssertThrowsError(try native.sample())
        XCTAssertThrowsError(try native.verify(targetID: target))
        assertRejected("preflight_failed") { try native.press(targetID: target) }
        XCTAssertEqual(client.readCount, 2)
        XCTAssertTrue(client.pressedElements.isEmpty)
    }

    func testBudgetExpiringDuringFinalFocusCheckPreventsDispatch() throws {
        let client = CallEndAccessibilityStub([call()])
        let native = backend(client)
        let target = try XCTUnwrap(native.sample().targetID)
        client.onFocus = { [weak client] in client?.uptime = 8 }
        assertRejected("preflight_failed") { try native.press(targetID: target) }
        XCTAssertTrue(client.pressedElements.isEmpty)
    }

    func testBudgetExpiringAfterPressLeavesOutcomeUncertainWithoutRetry() throws {
        let client = CallEndAccessibilityStub([call()])
        client.onPress = { [weak client] in client?.uptime = 8 }
        assertUncertain(try CallEndController(backend: backend(client)).end(), reason: "action_outcome_unknown")
        XCTAssertEqual(client.pressedElements.count, 1)
        XCTAssertEqual(client.readCount, 3)
    }

    private func backend(_ client: CallEndAccessibilityStub) -> AccessibilityCallEndBackend {
        AccessibilityCallEndBackend(accessibility: client, checkFocus: {
            client.onFocus?()
            return client.focus
        }, waitForUpdate: {
            client.waitCount += 1
            client.uptime += 0.15
        })
    }

    private func generation(pid: pid_t = 123, launch: TimeInterval = 1) -> MediaProcessGeneration {
        MediaProcessGeneration(pid: pid, launched: Date(timeIntervalSince1970: launch))
    }

    private func call(index: Int = 1, window: pid_t = 10, buttons: [pid_t] = [11],
                      held: Bool = false, label: String = "Leave", complete: Bool = true) -> TeamsSnapshot {
        var controls = buttons.map { _ in ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: label) }
        if held { controls.append(ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")) }
        let handles = CallWindowHandles(application: .current, window: AXUIElementCreateApplication(window),
                                        hangups: buttons.map(AXUIElementCreateApplication))
        return TeamsSnapshot(windows: [WindowSnapshot(index: index, controls: controls)], complete: complete,
                             focusUnchanged: true, handles: [index: handles])
    }

    private func closed() -> TeamsSnapshot { call(window: 20, buttons: []) }
    private func empty() -> TeamsSnapshot { TeamsSnapshot(windows: [], complete: true, focusUnchanged: true) }

    private func combining(_ first: TeamsSnapshot, _ second: TeamsSnapshot) -> TeamsSnapshot {
        TeamsSnapshot(windows: first.windows + second.windows, complete: first.complete && second.complete,
                      focusUnchanged: true, handles: first.handles.merging(second.handles) { first, _ in first })
    }

    private func assertRejected(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                                _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? CallEndPressRejected)?.reason, reason, file: file, line: line)
        }
    }

    private func assertRefused(_ result: CallEndResult, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertFalse(result.actionAttempted, file: file, line: line)
        XCTAssertEqual(result.changed, false, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
    }

    private func assertUncertain(_ result: CallEndResult, reason: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(result.success, file: file, line: line)
        XCTAssertEqual(result.state, .unknown, file: file, line: line)
        XCTAssertTrue(result.actionAttempted, file: file, line: line)
        XCTAssertNil(result.changed, file: file, line: line)
        XCTAssertEqual(result.reason, reason, file: file, line: line)
    }
}

/// AX elements are identity tokens only. All reads and actions are simulated;
/// neither Teams nor the process represented by a token is inspected or controlled.
private final class CallEndAccessibilityStub: MediaAccessibilityClient {
    var snapshots: [TeamsSnapshot]
    var uptime: TimeInterval = 0
    var windowGeneration: MediaProcessGeneration? = MediaProcessGeneration(pid: 123, launched: Date(timeIntervalSince1970: 1))
    var runningGeneration: MediaProcessGeneration? = MediaProcessGeneration(pid: 123, launched: Date(timeIntervalSince1970: 1))
    var attributes = ["AXRole": "AXButton", "AXDOMIdentifier": "hangup-button", "AXDescription": "Leave"]
    var focus: Bool? = true
    var pressError = AXError.success
    var failedRead: Int?
    var onRead: ((Int) -> Void)?
    var onValueRead: (() -> Void)?
    var onCanPress: ((Int) -> Bool)?
    var onFocus: (() -> Void)?
    var onPress: (() -> Void)?
    var waitCount = 0
    private(set) var readCount = 0
    private(set) var readCountAtPress = 0
    private(set) var pressedElements: [AXUIElement] = []
    private(set) var controls: [MediaControl] = []
    private(set) var timeouts: [TimeInterval] = []
    private var readinessChecks = 0

    init(_ snapshots: [TeamsSnapshot]) { self.snapshots = snapshots }

    func read(control: MediaControl, timeout: TimeInterval) throws -> TeamsSnapshot {
        controls.append(control)
        timeouts.append(timeout)
        readCount += 1
        onRead?(readCount)
        if readCount == failedRead { throw TeamsReadError.accessibilityFailure(-25204) }
        return snapshots[min(readCount - 1, snapshots.count - 1)]
    }

    func generation(of application: NSRunningApplication) -> MediaProcessGeneration? { windowGeneration }

    func processMatches(pid: pid_t, launched: Date) -> Bool {
        runningGeneration == MediaProcessGeneration(pid: pid, launched: launched)
    }

    func canPress(_ element: AXUIElement) -> Bool {
        let index = readinessChecks
        readinessChecks += 1
        return onCanPress?(index) ?? true
    }

    func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        onValueRead?()
        return attributes[name].map { $0 as CFString }
    }

    func press(_ element: AXUIElement) -> AXError {
        pressedElements.append(element)
        readCountAtPress = readCount
        onPress?()
        return pressError
    }
}
