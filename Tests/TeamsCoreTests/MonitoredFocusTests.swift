import ApplicationServices
import XCTest
@testable import TeamsCore

final class MonitoredFocusTests: XCTestCase {
    func testCaptureBracketsWindowReadWithForegroundApplicationChecks() throws {
        var events: [String] = []
        let window = AXUIElementCreateApplication(10)
        let snapshot = MonitoredFocus.capture(frontmostPID: {
            events.append("pid")
            return 123
        }, focusedWindow: { pid in
            events.append("window \(pid)")
            return window
        })
        XCTAssertEqual(snapshot.pid, 123)
        XCTAssertTrue(CFEqual(try XCTUnwrap(snapshot.window), window))
        XCTAssertEqual(events, ["pid", "window 123", "pid"])
    }

    func testMissingForegroundApplicationDoesNotReadAnyWindow() {
        let snapshot = MonitoredFocus.capture(frontmostPID: { nil }, focusedWindow: { _ in
            XCTFail("No window should be read without a foreground process")
            return nil
        })
        XCTAssertNil(snapshot.pid)
        XCTAssertNil(snapshot.window)
    }

    func testUnavailableWindowPreservesKnownProcessButNotWindowEvidence() {
        let snapshot = MonitoredFocus.capture(frontmostPID: { 123 }, focusedWindow: { _ in nil })
        XCTAssertEqual(snapshot.pid, 123)
        XCTAssertNil(snapshot.window)
    }

    func testApplicationChangeOrDisappearanceDuringWindowReadDiscardsOldWindow() {
        for after: pid_t? in [456, nil] {
            var current: pid_t? = 123
            let snapshot = MonitoredFocus.capture(frontmostPID: { current }, focusedWindow: { _ in
                current = after
                return AXUIElementCreateApplication(10)
            })
            XCTAssertEqual(snapshot.pid, after)
            XCTAssertNil(snapshot.window)
        }
    }
}
