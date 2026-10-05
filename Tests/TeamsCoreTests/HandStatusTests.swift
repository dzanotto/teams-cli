import XCTest
import Accessibility
@testable import TeamsCore

final class HandStatusTests: XCTestCase {
    func testCustomActionDescriptionDeterminesStateDespiteStaticRaiseTitle() {
        let raised = assess(call(1, "Lower your hand"))
        XCTAssertEqual(raised.state, .raised)
        XCTAssertNil(raised.reason)
        let lowered = assess(call(3, "Raise your hand"))
        XCTAssertEqual(lowered.state, .lowered)
        XCTAssertNil(lowered.reason)
        XCTAssertEqual(lowered.windows, [WindowHandStatus(window: 3, state: .lowered)])
    }

    func testActionDescriptionsCanAlsoBeExposedAsTheMainLabel() {
        for (label, expected) in [("Lower your hand", HandState.raised), ("Raise your hand", .lowered)] {
            let control = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: label)
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, control])).state, expected)
        }
    }

    func testStaticTitleAloneNeverEstablishesState() {
        for label in ["Raise", "Lower", "Hand", "Raised", "Alza"] {
            let control = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: label)
            let result = assess(WindowSnapshot(index: 1, controls: [hangup, control]))
            XCTAssertEqual(result.state, .unknown, label)
            XCTAssertEqual(result.reason, "unrecognized_hand_label", label)
        }
    }

    func testItalianLabelsAndShortcutSuffixes() {
        for label in ["Lower hand", "Abbassa la mano", "Lower your hand (⇧⌘K)", "Lower hand (Command+Shift+K)"] {
            XCTAssertEqual(assess(call(1, label)).state, .raised, label)
        }
        for label in ["Raise hand", "Alza la mano", "Raise your hand (Ctrl + Shift + K)", "Alza la mano (Comando+Maiusc+K)"] {
            XCTAssertEqual(assess(call(1, label)).state, .lowered, label)
        }
    }

    func testCaseAndWhitespaceAreNormalized() {
        XCTAssertEqual(assess(call(1, "  LOWER\n YOUR\tHAND  ")).state, .raised)
    }

    func testUnknownDescriptionsAndParticipantActionsCannotBeGuessed() {
        for label in ["", "Hand raised", "Raise", "Lower Alice's hand", "Lower all hands",
                      "Raise your hand for Alice", "Lower your hand (for everyone)", "Raise your hand (K)"] {
            let result = assess(call(1, label))
            XCTAssertEqual(result.state, .unknown, label)
            XCTAssertEqual(result.reason, "unrecognized_hand_label", label)
        }
    }

    func testParticipantControlsAndSimilarIdentifiersAreIgnored() {
        let unrelated = [
            ControlSnapshot(role: "AXButton", identifier: "participant-raisehands-button", label: "Lower your hand"),
            ControlSnapshot(role: "AXStaticText", identifier: "raisehands-button", label: "Lower your hand"),
            ControlSnapshot(role: "AXButton", identifier: "raisehands-button-extra", label: "Lower your hand"),
            ControlSnapshot(role: "AXButton", identifier: "raisehand-button", label: "Lower your hand"),
        ]
        let missing = assess(WindowSnapshot(index: 1, controls: [hangup] + unrelated))
        XCTAssertEqual(missing.state, .unknown)
        XCTAssertEqual(missing.reason, "hand_control_missing")
        let own = assess(WindowSnapshot(index: 1, controls: [hangup, hand("Raise your hand")] + unrelated))
        XCTAssertEqual(own.state, .lowered)
    }

    func testPrejoinHandControlDoesNotEstablishACall() {
        let result = assess(WindowSnapshot(index: 1, controls: [hand("Raise your hand")]))
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "no_call_controls")
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testHangupMustBeAnExactButtonInTheSameWindow() {
        for fake in [
            ControlSnapshot(role: "AXButton", identifier: "hangup-button-extra", label: "Leave"),
            ControlSnapshot(role: "AXStaticText", identifier: "hangup-button", label: "Leave"),
        ] {
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [fake, hand("Lower your hand")])).reason,
                           "no_call_controls")
        }
        let result = HandClassifier.assess([
            WindowSnapshot(index: 1, controls: [hand("Lower your hand")]),
            WindowSnapshot(index: 2, controls: [hangup]),
        ], complete: true)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reason, "hand_control_missing")
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 2, state: .unknown)])
    }

    func testHeldCallsAreExcludedAndWindowIndicesArePreserved() {
        let result = HandClassifier.assess([held(2), call(5, "Lower your hand")], complete: true)
        XCTAssertEqual(result.state, .raised)
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 5, state: .raised)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testAllHeldCallsIncludingAnExplicitlySelectedHeldWindowAreUnknown() {
        for windows in [[held(2)], [held(2), held(3)]] {
            let result = HandClassifier.assess(windows, complete: true)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "all_calls_on_hold")
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertEqual(result.excludedWindows.count, windows.count)
        }
    }

    func testIncompleteScansTakePrecedenceWhilePreservingPartialObservations() {
        for windows in [[], [held(2)], [call(1, "Lower your hand"), call(2, "Raise your hand")]] {
            let result = HandClassifier.assess(windows, complete: false)
            XCTAssertEqual(result.state, .unknown)
            XCTAssertEqual(result.reason, "inspection_incomplete")
        }
        let result = HandClassifier.assess([held(2), call(5, "Lower your hand")], complete: false)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.windows, [WindowHandStatus(window: 5, state: .raised)])
        XCTAssertEqual(result.excludedWindows, [ExcludedWindow(window: 2, reason: "on_hold")])
    }

    func testMultipleActiveCallsAreAmbiguousEvenWhenStatesAgree() {
        for second in ["Lower your hand", "Raise your hand"] {
            let result = HandClassifier.assess([held(2), call(4, "Lower your hand"), call(8, second)], complete: true)
            XCTAssertEqual(result.state, .ambiguous)
            XCTAssertEqual(result.reason, "multiple_call_windows")
            XCTAssertEqual(result.windows.map(\.window), [4, 8])
        }
    }

    func testConflictingActionDescriptionsWithinOrAcrossButtonsAreAmbiguous() {
        let conflicting = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise",
                                          detailLabels: ["Raise your hand", "Lower your hand"])
        for controls in [[conflicting], [hand("Raise your hand"), hand("Lower your hand")]] {
            let result = assess(WindowSnapshot(index: 1, controls: [hangup] + controls))
            XCTAssertEqual(result.state, .ambiguous)
            XCTAssertEqual(result.reason, "conflicting_hand_controls")
        }
    }

    func testDuplicateControlsMustAllHaveRecognizedConsistentDescriptions() {
        let consistent = assess(WindowSnapshot(index: 1, controls: [hangup, hand("Lower your hand"), hand("Lower your hand")]))
        XCTAssertEqual(consistent.state, .raised)
        let unknown = assess(WindowSnapshot(index: 1, controls: [hangup, hand("Lower your hand"), hand("Hand")]))
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertEqual(unknown.reason, "unrecognized_hand_label")
    }

    func testMicrophoneAndCameraStatesDoNotDetermineHandState() {
        let media = [
            ControlSnapshot(role: "AXButton", identifier: "microphone-button", label: "Unmute mic"),
            ControlSnapshot(role: "AXButton", identifier: "video-button", label: "Turn camera off"),
        ]
        XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup] + media)).reason, "hand_control_missing")
        XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, hand("Lower your hand")] + media)).state, .raised)
    }

    func testSecureCustomContentDecodingReadsTheActionValue() throws {
        for (action, expected) in [("Lower your hand", HandState.raised), ("Raise your hand", .lowered)] {
            let content = AXCustomContent(label: "description", value: action)
            content.importance = .high
            let data = try NSKeyedArchiver.archivedData(withRootObject: [content], requiringSecureCoding: true)
            let labels = AccessibilityCustomContent.labels(from: data)
            XCTAssertEqual(labels, [action])
            let control = ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise", detailLabels: labels)
            XCTAssertEqual(assess(WindowSnapshot(index: 1, controls: [hangup, control])).state, expected)
        }
    }

    func testMalformedMissingOrOversizedCustomContentProvidesNoState() {
        let samples: [Any?] = [nil, "Lower your hand", Data(), Data("not an archive".utf8), Data(repeating: 0, count: 262_145)]
        for raw in samples {
            XCTAssertTrue(AccessibilityCustomContent.labels(from: raw).isEmpty)
        }
    }

    func testUnexpectedArchiveRootOrEntryTypesProvideNoState() throws {
        for root in ["Lower your hand" as NSString, ["Lower your hand"] as NSArray, NSDate()] {
            let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true)
            XCTAssertTrue(AccessibilityCustomContent.labels(from: data).isEmpty)
        }
    }

    func testControlSnapshotsRemainBackwardCompatibleAndPreserveExtraDescriptions() throws {
        let original = Data(#"{"role":"AXButton","identifier":"microphone-button","label":"Mute mic"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ControlSnapshot.self, from: original).detailLabels)
        let control = hand("Lower your hand")
        let encoded = try JSONEncoder().encode(control)
        XCTAssertEqual(try JSONDecoder().decode(ControlSnapshot.self, from: encoded), control)
    }

    private var hangup: ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "hangup-button", label: "Leave")
    }

    private func hand(_ description: String) -> ControlSnapshot {
        ControlSnapshot(role: "AXButton", identifier: "raisehands-button", label: "Raise", detailLabels: [description])
    }

    private func call(_ index: Int, _ description: String) -> WindowSnapshot {
        WindowSnapshot(index: index, controls: [hangup, hand(description)])
    }

    private func held(_ index: Int) -> WindowSnapshot {
        WindowSnapshot(index: index, controls: [hangup, hand("Lower your hand"),
            ControlSnapshot(role: "AXButton", identifier: "resume-button", label: "Resume")])
    }

    private func assess(_ window: WindowSnapshot) -> HandAssessment {
        HandClassifier.assess([window], complete: true)
    }
}
