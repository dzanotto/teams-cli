import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class TeamsAccessibilityReaderTests: XCTestCase {
    func testPermissionDeniedStopsBeforeApplicationDiscoveryOrAccessibilityReads() {
        let stub = AccessibilityReaderStub()
        stub.trusted = false
        XCTAssertThrowsError(try stub.read()) { error in
            guard case TeamsReadError.accessibilityDenied = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(stub.events, ["permission"])
        XCTAssertTrue(stub.messagingTimeouts.isEmpty)
    }

    func testTeamsNotRunningStopsBeforeHelperAndFocusReads() {
        let stub = AccessibilityReaderStub()
        stub.applications = []
        XCTAssertThrowsError(try stub.read()) { error in
            guard case TeamsReadError.notRunning = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(stub.events, ["permission", "com.microsoft.teams2"])
        XCTAssertTrue(stub.messagingTimeouts.isEmpty)
    }

    func testOnlyExactWebViewBrowserHelpersArePrimedBeforeScanning() throws {
        let stub = AccessibilityReaderStub()
        stub.window([stub.button()])
        let names: [String?] = ["Microsoft Teams WebView (Renderer)", "Microsoft Teams WebView",
                                nil, "Microsoft Teams WebView Helper", "Microsoft Teams WebView"]
        stub.helpers = names.map { stub.application(stub.node("AXApplication"), executable: $0) }
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(stub.bundleQueries, ["com.microsoft.teams2", "com.microsoft.teams2.helper"])
        let primed = stub.singleReads.filter { $0.name == kAXRoleAttribute }.map(\.element)
        XCTAssertEqual(primed, [stub.helpers[1].element, stub.helpers[4].element])
        XCTAssertEqual(Array(stub.events.prefix(7)), ["permission", "com.microsoft.teams2", "focus",
                                                     "com.microsoft.teams2.helper", "AXRole", "AXRole", "AXWindows"])
        XCTAssertTrue(stub.messagingTimeouts.allSatisfy { $0.seconds == 0.25 })
        let timed = Set(stub.messagingTimeouts.map(\.element))
        XCTAssertTrue(Set(primed + [stub.root] + stub.traversed).isSubset(of: timed))
        XCTAssertFalse(timed.contains(stub.helpers[0].element))
    }

    func testFailedHelperPrimingDoesNotDiscardAnOtherwiseCompleteTree() throws {
        let stub = AccessibilityReaderStub()
        let helper = stub.node("AXApplication")
        stub.helpers = [stub.application(helper, executable: "Microsoft Teams WebView")]
        stub.singleErrors[helper] = .cannotComplete
        stub.window([stub.button()])
        XCTAssertTrue(try stub.read().complete)
        XCTAssertEqual(stub.windowReadCount, 1)
    }

    func testSupportedButtonsAreCollectedWithMatchingNativeHandles() throws {
        let stub = AccessibilityReaderStub()
        let microphone = stub.button()
        let camera = stub.button("video-button", label: "Turn camera off")
        let hangup = stub.button("hangup-button", label: "Leave")
        let resume = stub.button("resume-button", label: "Resume")
        let ignored = stub.button("share-button")
        let nonButton = stub.node("AXStaticText", attributes: ["AXDOMIdentifier": "microphone-button"])
        let window = stub.window([microphone, camera, hangup, resume, ignored, nonButton])
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.windows, [WindowSnapshot(index: 1, controls: [
            ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: "Mute mic"),
            ControlSnapshot(role: "AXButton", identifier: "video-button", label: "Turn camera off"),
            ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave"),
            ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")
        ])])
        let handles = try XCTUnwrap(result.handles[1])
        XCTAssertEqual(handles.window, window)
        XCTAssertTrue(handles.application === stub.applications[0].application)
        XCTAssertEqual(handles.microphones, [microphone])
        XCTAssertEqual(handles.cameras, [camera])
        XCTAssertEqual(handles.hangups, [hangup])
        XCTAssertTrue(handles.hands.isEmpty)
        XCTAssertEqual(MicrophoneClassifier.assess(result.windows, complete: result.complete).reason,
                       "all_calls_on_hold")
        XCTAssertFalse(stub.batchReads.contains { $0.element == ignored && $0.names.contains(kAXDescriptionAttribute) })
        XCTAssertFalse(stub.batchReads.contains { $0.element == nonButton && $0.names.contains("AXDOMIdentifier") })
        XCTAssertTrue(stub.sleeps.isEmpty)
    }

    func testIdentifiersUseFirstRecognizedDOMOrAXIdentifier() throws {
        let cases: [(Any?, Any?, String?)] = [
            ("microphone-button", "video-button", "microphone-button"),
            ("other", "microphone-button", "microphone-button"),
            (nil, "microphone-button", "microphone-button"),
            (12, "microphone-button", "microphone-button"),
            ("Microphone-button", "other", nil)
        ]
        for (domID, axID, expected) in cases {
            let stub = AccessibilityReaderStub()
            let button = stub.button()
            stub.values[button]?["AXDOMIdentifier"] = domID
            stub.values[button]?[kAXIdentifierAttribute] = axID
            stub.window([button])
            let result = try stub.read(timeout: 0.25)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.windows[0].controls.map(\.identifier), expected.map { [$0] } ?? [])
            XCTAssertEqual(result.handles[1]?.microphones, expected == nil ? [] : [button])
        }
    }

    func testButtonLabelsUseFirstNonemptyDescriptionTitleOrHelp() throws {
        let cases: [(Any?, Any?, Any?, String)] = [
            ("Description", "Title", "Help", "Description"),
            ("", "Title", "Help", "Title"),
            (nil, "", "Help", "Help"),
            (42, nil, "Help", "Help"),
            (nil, nil, nil, "")
        ]
        for (description, title, help, expected) in cases {
            let stub = AccessibilityReaderStub()
            let button = stub.button()
            stub.values[button]?[kAXDescriptionAttribute] = description
            stub.values[button]?[kAXTitleAttribute] = title
            stub.values[button]?[kAXHelpAttribute] = help
            stub.window([button])
            let result = try stub.read()
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.windows[0].controls.first?.label, expected)
        }
    }

    func testHandReadCollectsOwnVideoAndHandButtonButExcludesParticipantTiles() throws {
        let stub = AccessibilityReaderStub()
        let hand = stub.button("raisehands-button", label: "Raise your hand")
        let label = "Myself video, Test User, Video is off, Hand raised position 1, Has context menu"
        let ownVideo = stub.node("AXImage", attributes: [kAXDescriptionAttribute: label])
        let participant = stub.node("AXImage", attributes: [kAXDescriptionAttribute: "Another video, Hand raised position 1"])
        let wrongRole = stub.node("AXStaticText", attributes: [kAXDescriptionAttribute: label])
        stub.window([hand, stub.button("hangup-button", label: "Leave"), ownVideo, participant, wrongRole])
        let result = try stub.read(control: .hand)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.handles[1]?.hands, [hand])
        XCTAssertEqual(result.handles[1]?.ownVideos, [ownVideo])
        XCTAssertEqual(result.windows[0].controls.filter { $0.role == "AXImage" },
                       [ControlSnapshot(role: "AXImage", identifier: "", label: label)])
        XCTAssertEqual(HandClassifier.assess(result.windows, complete: result.complete).state, .raised)
        XCTAssertTrue(stub.sleeps.isEmpty)
    }

    func testOtherControlReadsSkipHandButtonsAndImageDescriptions() throws {
        for control in [MediaControl.microphone, .camera, .call] {
            let stub = AccessibilityReaderStub()
            let hand = stub.button("raisehands-button")
            let image = stub.node("AXImage", attributes: [kAXDescriptionAttribute: "Myself video"])
            stub.window([stub.button(control.rawValue), hand, image])
            let result = try stub.read(control: control)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.windows[0].controls.map(\.identifier), [control.rawValue])
            XCTAssertEqual(result.handles[1]?.hands, [])
            XCTAssertEqual(result.handles[1]?.ownVideos, [])
            XCTAssertFalse(stub.batchReads.contains { ($0.element == hand || $0.element == image) &&
                $0.names.contains(kAXDescriptionAttribute) })
        }
    }

    func testMultipleWindowsKeepControlsAndHandlesSeparate() throws {
        let stub = AccessibilityReaderStub()
        let microphone = stub.button()
        let hangup = stub.button("hangup-button", label: "Leave")
        let first = stub.window([microphone])
        let second = stub.window([hangup])
        let empty = stub.window()
        let result = try stub.read()
        XCTAssertEqual(result.windows.map(\.index), [1, 2, 3])
        XCTAssertEqual(result.windows.map { $0.controls.map(\.identifier) }, [["microphone-button"], ["hangup-button"], []])
        XCTAssertEqual(result.handles[1]?.window, first)
        XCTAssertEqual(result.handles[2]?.window, second)
        XCTAssertEqual(result.handles[3]?.window, empty)
        XCTAssertEqual(result.handles[1]?.microphones, [microphone])
        XCTAssertEqual(result.handles[2]?.microphones, [])
        XCTAssertEqual(result.handles[1]?.hangups, [])
        XCTAssertEqual(result.handles[2]?.hangups, [hangup])
        // A microphone in one window must not become a call control in another.
        XCTAssertEqual(MicrophoneClassifier.assess(result.windows, complete: result.complete).reason,
                       "microphone_control_missing")
    }

    func testWindowIndicesRemainUniqueAcrossApplications() throws {
        let stub = AccessibilityReaderStub()
        let first = stub.window([stub.button()])
        let second = stub.node("AXWindow", children: [stub.button()])
        let otherRoot = stub.node("AXApplication", attributes: [kAXWindowsAttribute: [second]])
        stub.applications.append(stub.application(otherRoot))
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.windows.map(\.index), [1, 2])
        XCTAssertEqual(result.handles[1]?.window, first)
        XCTAssertEqual(result.handles[2]?.window, second)
        XCTAssertEqual(Set(result.handles.keys), [1, 2])
        XCTAssertEqual(stub.windowReadCount, 2)
    }

    func testCyclesAndRepeatedEdgesVisitEachNodeOnce() throws {
        let stub = AccessibilityReaderStub()
        let button = stub.button()
        let group = stub.node(children: [button, button])
        let window = stub.window([group, group, button])
        stub.values[button]?[kAXChildrenAttribute] = [window, group]
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(stub.traversed, [window, group, button])
        XCTAssertEqual(result.handles[1]?.microphones, [button])
        XCTAssertEqual(result.windows[0].controls.count, 1)
    }

    func testDistinctButtonsWithConflictingLabelsRemainVisibleToClassifier() throws {
        let stub = AccessibilityReaderStub()
        let first = stub.button(label: "Mute mic")
        let second = stub.button(label: "Unmute mic")
        stub.window([first, second, stub.button("hangup-button", label: "Leave")])
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.handles[1]?.microphones, [first, second])
        let assessment = MicrophoneClassifier.assess(result.windows, complete: result.complete)
        XCTAssertEqual(assessment.state, .ambiguous)
        XCTAssertEqual(assessment.reason, "conflicting_microphone_controls")
    }

    func testDuplicateWindowsMakeInspectionIncompleteWithoutDuplicatingControls() throws {
        let stub = AccessibilityReaderStub()
        let window = stub.window([stub.button()])
        stub.values[stub.root]?[kAXWindowsAttribute] = [window, window]
        let result = try stub.read()
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.windows.map { $0.controls.count }, [1, 0])
        XCTAssertEqual(stub.traversed.filter { $0 == window }.count, 1)
        XCTAssertTrue(stub.sleeps.isEmpty)
    }

    func testDepthLimitIncludesDepth80ButRejectsUnvisitedDescendants() throws {
        for overflow in [false, true] {
            let stub = AccessibilityReaderStub()
            let window = stub.window()
            var parent = window
            for depth in 1...80 {
                let child = depth == 80 ? stub.button() : stub.node()
                stub.values[parent]?[kAXChildrenAttribute] = [child]
                parent = child
            }
            let beyondLimit = stub.button("video-button")
            if overflow { stub.values[parent]?[kAXChildrenAttribute] = [beyondLimit] }
            let result = try stub.read()
            XCTAssertEqual(result.complete, !overflow)
            XCTAssertEqual(stub.traversed.count, 81)
            XCTAssertFalse(stub.traversed.contains(beyondLimit))
            XCTAssertEqual(result.handles[1]?.microphones, [parent])
            XCTAssertEqual(result.handles[1]?.cameras, [])
        }
    }

    func testNodeBudgetIncludes12000NodesAndRejectsOverflow() throws {
        for overflow in [false, true] {
            let stub = AccessibilityReaderStub()
            let microphone = stub.button()
            let others = (0..<11_998).map { _ in stub.node() }
            let extra = stub.button("video-button")
            stub.window([microphone] + others + (overflow ? [extra] : []))
            let result = try stub.read()
            XCTAssertEqual(result.complete, !overflow)
            XCTAssertEqual(stub.traversed.count, 12_000)
            XCTAssertEqual(result.handles[1]?.microphones, [microphone])
            XCTAssertFalse(stub.traversed.contains(extra))
            XCTAssertTrue(stub.sleeps.isEmpty)
        }
    }

    func testNodeBudgetIsSharedAcrossWindowsAndApplications() throws {
        let stub = AccessibilityReaderStub()
        let first = stub.window((0..<11_999).map { _ in stub.node() })
        let second = stub.window([stub.button()])
        let third = stub.node("AXWindow", children: [stub.button()])
        let otherRoot = stub.node("AXApplication", attributes: [kAXWindowsAttribute: [third]])
        stub.applications.append(stub.application(otherRoot))
        let result = try stub.read()
        XCTAssertFalse(result.complete)
        XCTAssertEqual(stub.traversed.count, 12_000)
        XCTAssertEqual(stub.traversed.first, first)
        XCTAssertFalse(stub.traversed.contains(second))
        XCTAssertFalse(stub.traversed.contains(third))
        XCTAssertEqual(result.windows.map(\.index), [1, 2, 3])
        XCTAssertTrue(result.windows.allSatisfy { $0.controls.isEmpty })
        XCTAssertTrue(stub.sleeps.isEmpty)
    }

    func testTimeoutIsClampedToZeroAndEightSeconds() throws {
        for (timeout, expectedReads) in [(-1.0, 0), (0.0, 0), (2.0, 2), (8.0, 8), (30.0, 8)] {
            let stub = AccessibilityReaderStub()
            stub.window((0..<20).map { _ in stub.node() })
            stub.onBatchRead = { [unowned stub] _, _ in stub.now += 1 }
            let result = try stub.read(timeout: timeout)
            XCTAssertFalse(result.complete)
            XCTAssertEqual(stub.traversed.count, expectedReads)
            XCTAssertTrue(stub.sleeps.isEmpty)
        }
    }

    func testDeadlineIsSharedAcrossWindows() throws {
        let stub = AccessibilityReaderStub()
        let first = stub.window()
        let second = stub.window()
        stub.onBatchRead = { [unowned stub] _, _ in stub.now += 1 }
        let result = try stub.read(timeout: 1)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(stub.traversed, [first])
        XCTAssertEqual(result.handles[2]?.window, second)
    }

    func testWindowReadFailuresPropagateTheirNativeError() {
        for error in [AXError.cannotComplete, .invalidUIElement, .attributeUnsupported, .noValue] {
            let stub = AccessibilityReaderStub()
            stub.singleErrors[stub.root] = error
            assertReadFailure(stub, code: error.rawValue)
            XCTAssertTrue(stub.batchReads.isEmpty)
            XCTAssertTrue(stub.sleeps.isEmpty)
        }
    }

    func testMissingOrWrongTypeWindowListIsRejectedEvenWhenNativeReadReportsSuccess() {
        for missing in [false, true] {
            let stub = AccessibilityReaderStub()
            stub.values[stub.root]?[kAXWindowsAttribute] = "not a window list"
            if missing { stub.singleErrors[stub.root] = .success }
            assertReadFailure(stub, code: AXError.success.rawValue)
            XCTAssertTrue(stub.batchReads.isEmpty)
        }
    }

    func testLaterApplicationReadFailureCannotReturnEarlierPartialSuccess() {
        let stub = AccessibilityReaderStub()
        stub.window([stub.button()])
        let otherRoot = stub.node("AXApplication")
        stub.applications.append(stub.application(otherRoot))
        stub.singleErrors[otherRoot] = .cannotComplete
        assertReadFailure(stub, code: AXError.cannotComplete.rawValue)
        XCTAssertEqual(stub.windowReadCount, 2)
        XCTAssertFalse(stub.traversed.isEmpty)
    }

    func testMalformedOrFailedBatchReadsMakeInspectionIncomplete() throws {
        let responses: [(CFArray?, AXError)] = [
            (nil, .cannotComplete), (nil, .success),
            (["AXWindow"] as CFArray, .success),
            (["AXWindow", [AXUIElement](), "extra"] as CFArray, .success)
        ]
        for response in responses {
            let stub = AccessibilityReaderStub()
            stub.window()
            stub.batchOverride = { _, _ in response }
            let result = try stub.read()
            XCTAssertFalse(result.complete)
            XCTAssertTrue(result.windows[0].controls.isEmpty)
            XCTAssertEqual(stub.windowReadCount, 1)
            XCTAssertTrue(stub.sleeps.isEmpty)
        }
    }

    func testMissingOptionalAttributesAndLeafChildrenRemainComplete() throws {
        for absence in [AXError.attributeUnsupported, .noValue] {
            let stub = AccessibilityReaderStub()
            let button = stub.button()
            stub.values[button]?[kAXChildrenAttribute] = readerAXError(absence)
            stub.values[button]?["AXDOMIdentifier"] = readerAXError(absence)
            stub.values[button]?[kAXIdentifierAttribute] = "microphone-button"
            stub.values[button]?[kAXDescriptionAttribute] = readerAXError(absence)
            stub.values[button]?[kAXTitleAttribute] = "Unmute mic"
            stub.values[button]?[kAXHelpAttribute] = readerAXError(absence)
            stub.window([button])
            let result = try stub.read()
            XCTAssertTrue(result.complete)
            XCTAssertEqual(result.windows[0].controls.first?.label, "Unmute mic")
            XCTAssertEqual(result.handles[1]?.microphones, [button])
        }
    }

    func testMissingEmptyOrNonStringRoleMakesInspectionIncomplete() throws {
        for role: Any in [readerAXError(.noValue), "", 12] {
            let stub = AccessibilityReaderStub()
            let window = stub.window()
            stub.values[window]?[kAXRoleAttribute] = role
            XCTAssertFalse(try stub.read().complete)
            XCTAssertTrue(stub.sleeps.isEmpty)
        }
    }

    func testWrappedCommunicationErrorsInEveryReadStageMakeInspectionIncomplete() throws {
        for stage in ["role", "children", "identity", "label", "image"] {
            let stub = AccessibilityReaderStub()
            let button = stub.button()
            let image = stub.node("AXImage", attributes: [kAXDescriptionAttribute: "Myself video"])
            let window = stub.window([button, image])
            switch stage {
            case "role": stub.values[window]?[kAXRoleAttribute] = readerAXError(.cannotComplete)
            case "children": stub.values[window]?[kAXChildrenAttribute] = readerAXError(.cannotComplete)
            case "identity": stub.values[button]?[kAXIdentifierAttribute] = readerAXError(.cannotComplete)
            case "label": stub.values[button]?[kAXHelpAttribute] = readerAXError(.cannotComplete)
            default: stub.values[image]?[kAXDescriptionAttribute] = readerAXError(.cannotComplete)
            }
            let result = try stub.read(control: .hand)
            XCTAssertFalse(result.complete, stage)
            XCTAssertEqual(stub.windowReadCount, 1, stage)
            XCTAssertTrue(stub.sleeps.isEmpty, stage)
        }
    }

    func testNonErrorAXValuesDoNotHideValidFallbackAttributes() throws {
        let stub = AccessibilityReaderStub()
        let button = stub.button()
        var point = CGPoint(x: 1, y: 2)
        stub.values[button]?["AXDOMIdentifier"] = AXValueCreate(.cgPoint, &point)!
        stub.values[button]?[kAXIdentifierAttribute] = "microphone-button"
        stub.window([button])
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.handles[1]?.microphones, [button])
    }

    func testReadableControlsCannotOverrideAnIncompleteNode() throws {
        let stub = AccessibilityReaderStub()
        let broken = stub.node()
        stub.values[broken]?[kAXChildrenAttribute] = readerAXError(.cannotComplete)
        stub.window([stub.button(), stub.button("hangup-button", label: "Leave"), broken])
        let result = try stub.read()
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.windows[0].controls.count, 2)
        let assessment = MicrophoneClassifier.assess(result.windows, complete: result.complete)
        XCTAssertEqual(assessment.state, .unknown)
        XCTAssertEqual(assessment.reason, "inspection_incomplete")
    }

    func testAbsentRequestedControlTriggersOneDelayedFreshScan() throws {
        let stub = AccessibilityReaderStub()
        let oldWindow = stub.window([stub.button("video-button")])
        let microphone = stub.button()
        let newWindow = stub.node("AXWindow", children: [microphone])
        stub.onSleep = { [unowned stub] in stub.values[stub.root]?[kAXWindowsAttribute] = [newWindow] }
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(stub.sleeps, [0.25])
        XCTAssertEqual(stub.windowReadCount, 2)
        XCTAssertTrue(stub.traversed.contains(oldWindow))
        XCTAssertTrue(stub.traversed.contains(newWindow))
        XCTAssertEqual(result.windows[0].controls.map(\.identifier), ["microphone-button"])
        XCTAssertEqual(result.handles[1]?.window, newWindow)
        XCTAssertEqual(result.handles[1]?.microphones, [microphone])
        XCTAssertEqual(result.handles[1]?.cameras, [])
    }

    func testEmptyTreeRetriesOnlyOnceEvenWhenStillEmpty() throws {
        let stub = AccessibilityReaderStub()
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.handles.isEmpty)
        XCTAssertEqual(stub.sleeps, [0.25])
        XCTAssertEqual(stub.windowReadCount, 2)
        XCTAssertEqual(stub.focusCaptureCount, 2)
    }

    func testRetryRescansPreviouslyVisitedElements() throws {
        let stub = AccessibilityReaderStub()
        let window = stub.window()
        let microphone = stub.button()
        stub.onSleep = { [unowned stub] in stub.values[window]?[kAXChildrenAttribute] = [microphone] }
        let result = try stub.read()
        XCTAssertTrue(result.complete)
        XCTAssertEqual(stub.traversed, [window, window, microphone])
        XCTAssertEqual(result.handles[1]?.microphones, [microphone])
    }

    func testRetryDependsOnRequestedControlRatherThanAnyKnownControl() throws {
        for control in [MediaControl.camera, .call, .hand] {
            let stub = AccessibilityReaderStub()
            let window = stub.window([stub.button()])
            let requested = stub.button(control.rawValue)
            stub.onSleep = { [unowned stub] in stub.values[window]?[kAXChildrenAttribute] = [requested] }
            let result = try stub.read(control: control)
            XCTAssertEqual(stub.sleeps, [0.25])
            XCTAssertEqual(result.windows[0].controls.map(\.identifier), [control.rawValue])
            XCTAssertEqual(result.handles[1]?.buttons(for: control), [requested])
        }
    }

    func testPresentRequestedControlInAnyWindowSuppressesRetry() throws {
        let stub = AccessibilityReaderStub()
        stub.window()
        stub.window([stub.button()])
        _ = try stub.read()
        XCTAssertTrue(stub.sleeps.isEmpty)
        XCTAssertEqual(stub.windowReadCount, 1)
    }

    func testRetryRequiresMoreThanItsDelayRemaining() throws {
        for timeout in [0.1, 0.25] {
            let stub = AccessibilityReaderStub()
            stub.window()
            XCTAssertTrue(try stub.read(timeout: timeout).complete)
            XCTAssertTrue(stub.sleeps.isEmpty)
            XCTAssertEqual(stub.windowReadCount, 1)
        }
    }

    func testRetryUsesOriginalDeadlineAndCanReturnIncomplete() throws {
        let stub = AccessibilityReaderStub()
        let window = stub.window()
        let button = stub.button()
        stub.onBatchRead = { [unowned stub] _, _ in stub.now += 0.2 }
        stub.onSleep = { [unowned stub] in stub.values[window]?[kAXChildrenAttribute] = [button] }
        let result = try stub.read(timeout: 0.5)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(stub.sleeps, [0.25])
        XCTAssertEqual(stub.traversed, [window, window])
        XCTAssertEqual(result.handles[1]?.microphones, [])
    }

    func testRetryWindowReadFailureIsPropagatedInsteadOfReturningFirstSnapshot() {
        let stub = AccessibilityReaderStub()
        stub.window()
        stub.onSleep = { [unowned stub] in stub.singleErrors[stub.root] = .cannotComplete }
        assertReadFailure(stub, code: AXError.cannotComplete.rawValue)
        XCTAssertEqual(stub.sleeps, [0.25])
        XCTAssertEqual(stub.windowReadCount, 2)
    }

    func testFocusComparisonReportsUnchangedChangedAndMissingEvidence() throws {
        let first = AXUIElementCreateApplication(20)
        let second = AXUIElementCreateApplication(21)
        let cases: [(ReaderFocusSnapshot, ReaderFocusSnapshot, Bool?)] = [
            (.init(pid: 1, window: first), .init(pid: 1, window: AXUIElementCreateApplication(20)), true),
            (.init(pid: 1, window: first), .init(pid: 1, window: second), false),
            (.init(pid: 1, window: first), .init(pid: 2, window: nil), false),
            (.init(pid: nil, window: first), .init(pid: 1, window: first), nil),
            (.init(pid: 1, window: first), .init(pid: nil, window: first), nil),
            (.init(pid: 1, window: nil), .init(pid: 1, window: first), nil),
            (.init(pid: 1, window: first), .init(pid: 1, window: nil), nil)
        ]
        for (before, after, expected) in cases {
            let stub = AccessibilityReaderStub()
            stub.window([stub.button()])
            stub.focusSnapshots = [before, after]
            let result = try stub.read()
            XCTAssertEqual(result.focusUnchanged, expected)
            XCTAssertTrue(result.complete)
            XCTAssertEqual(stub.focusCaptureCount, 2)
            XCTAssertEqual(stub.events.last, "focus")
        }
    }

    func testFocusComparisonSpansTheDelayedRetry() throws {
        let stub = AccessibilityReaderStub()
        stub.focusSnapshots = [.init(pid: 1, window: stub.focusWindow)]
        stub.onSleep = { [unowned stub] in stub.focusSnapshots.append(.init(pid: 2, window: nil)) }
        XCTAssertEqual(try stub.read().focusUnchanged, false)
        XCTAssertEqual(stub.focusCaptureCount, 2)
        XCTAssertEqual(stub.sleeps, [0.25])
    }

    private func assertReadFailure(_ stub: AccessibilityReaderStub, code: Int32,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try stub.read(), file: file, line: line) { error in
            guard case TeamsReadError.accessibilityFailure(let actual) = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertEqual(actual, code, file: file, line: line)
        }
    }
}
