import ApplicationServices
import XCTest
@testable import TeamsCore

final class MonitoredFocusTests: XCTestCase {
    func testNativeWindowReadReturnsExactElementAfterSettingTimeout() throws {
        let stub = AccessibilityAttributeStub()
        let window = AXUIElementCreateApplication(456)
        stub.value = window
        let result = try XCTUnwrap(MonitoredFocus.readFocusedWindow(pid: 123, attributes: stub.client))
        XCTAssertTrue(CFEqual(result, window))
        XCTAssertEqual(stub.events, ["application 123", "timeout", "read AXFocusedWindow"])
        XCTAssertEqual(stub.timeouts, [0.25])
        XCTAssertTrue(stub.writes.isEmpty)
    }

    func testNativeWindowReadRejectsErrorsMissingValuesAndIncorrectTypes() {
        let cases: [(CFTypeRef?, AXError)] = [
            (AXUIElementCreateApplication(456), .failure), (nil, .success),
            ("window" as CFString, .success), (kCFBooleanTrue, .success), (NSNumber(value: 1), .success)
        ]
        for (value, error) in cases {
            let stub = AccessibilityAttributeStub()
            stub.value = value
            stub.readError = error
            XCTAssertNil(MonitoredFocus.readFocusedWindow(pid: 123, attributes: stub.client))
            XCTAssertEqual(stub.events, ["application 123", "timeout", "read AXFocusedWindow"])
            XCTAssertEqual(stub.timeouts, [0.25])
            XCTAssertTrue(stub.writes.isEmpty)
        }
    }

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
