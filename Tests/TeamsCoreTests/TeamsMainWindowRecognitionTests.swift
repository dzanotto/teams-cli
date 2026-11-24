import XCTest
@testable import TeamsCore

final class TeamsMainWindowRecognitionTests: XCTestCase {
    func testRequiresBothExactMarkersWithTheirExpectedRoles() {
        var recognition = TeamsMainWindowRecognition()
        XCTAssertEqual(recognition.result, .unknown)
        recognition.observe(role: "AXGroup", identifiers: ["idna-me-control-avatar-trigger", "ms-searchux-input"])
        recognition.observe(role: "AXButton", identifiers: ["Idna-me-control-avatar-trigger"])
        recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input-suffix"])
        XCTAssertEqual(recognition.result, .unknown)
        recognition.observe(role: "AXButton", identifiers: ["idna-me-control-avatar-trigger"])
        XCTAssertEqual(recognition.result, .unknown)
        recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input"])
        XCTAssertEqual(recognition.result, .mainShell)
    }

    func testRecognizesMarkersInEitherOrderAndAcceptsIdentifierFallback() {
        for reverse in [false, true] {
            let markers = [("AXButton", "idna-me-control-avatar-trigger"), ("AXComboBox", "ms-searchux-input")]
            var recognition = TeamsMainWindowRecognition()
            for (role, identifier) in reverse ? Array(markers.reversed()) : markers {
                recognition.observe(role: role, identifiers: ["", identifier])
            }
            XCTAssertEqual(recognition.result, .mainShell)
        }
    }

    func testAnyCallControlConflictsEvenWhenItAppearsAfterBothMainShellMarkers() {
        for identifier in ["microphone-button", "video-button", "hangup-button", "resume-button", "raisehands-button"] {
            for callFirst in [false, true] {
                var recognition = TeamsMainWindowRecognition()
                if callFirst { recognition.observe(role: "AXButton", identifiers: [identifier]) }
                recognition.observe(role: "AXButton", identifiers: ["idna-me-control-avatar-trigger"])
                recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input"])
                if !callFirst { recognition.observe(role: "AXButton", identifiers: [identifier]) }
                XCTAssertEqual(recognition.result, .conflicting, identifier)
            }
        }
    }

    func testPopupLeaveConflictsWithShellMarkersButOtherPopupsDoNotIdentifyCallsOrProfiles() {
        for callFirst in [false, true] {
            var recognition = TeamsMainWindowRecognition()
            recognition.observe(role: "AXPopUpButton", identifiers: ["idna-me-control-avatar-trigger", "microphone-button",
                                                                     "video-button", "resume-button", "raisehands-button",
                                                                     "hangup-button-more-options"])
            XCTAssertEqual(recognition.result, .unknown)
            if callFirst { recognition.observe(role: "AXPopUpButton", identifiers: ["hangup-button"]) }
            recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input"])
            XCTAssertEqual(recognition.result, callFirst ? .callSurface : .unknown)
            recognition.observe(role: "AXButton", identifiers: ["idna-me-control-avatar-trigger"])
            if !callFirst { recognition.observe(role: "AXPopUpButton", identifiers: ["hangup-button"]) }
            XCTAssertEqual(recognition.result, .conflicting)
        }
    }

    func testCallSurfaceDoesNotRequireAMainShellMarker() {
        var recognition = TeamsMainWindowRecognition()
        recognition.observe(role: "AXButton", identifiers: ["hangup-button"])
        XCTAssertEqual(recognition.result, .callSurface)
        recognition.observe(role: "AXButton", identifiers: ["idna-me-control-avatar-trigger"])
        XCTAssertEqual(recognition.result, .callSurface)
    }

    func testIncompleteEvidenceCannotRecoverWithinTheSameScan() {
        var recognition = TeamsMainWindowRecognition()
        recognition.observe(role: "AXButton", identifiers: ["idna-me-control-avatar-trigger"])
        recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input"], complete: false)
        recognition.observe(role: "AXComboBox", identifiers: ["ms-searchux-input"])
        XCTAssertEqual(recognition.result, .incomplete)
        XCTAssertEqual(TeamsMainWindowRecognition().result, .unknown)
    }
}
