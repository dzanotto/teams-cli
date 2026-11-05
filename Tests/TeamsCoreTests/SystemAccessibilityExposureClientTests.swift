import ApplicationServices
import XCTest
@testable import TeamsCore

final class SystemAccessibilityExposureClientTests: XCTestCase {
    func testSelectsOnlyLiveProcessAndPinsItsIdentityBeforeSettingTimeout() throws {
        let stub = ExposureEnvironmentStub()
        stub.applications.insert(process(pid: 456, terminated: true), at: 0)
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        XCTAssertEqual(client.pid, 123)
        XCTAssertEqual(client.launched, Date(timeIntervalSince1970: 10))
        XCTAssertTrue(CFEqual(client.application, stub.attributes.application))
        XCTAssertEqual(stub.attributes.events, ["applications com.microsoft.teams2", "application 123", "timeout"])
        XCTAssertEqual(stub.attributes.timeouts, [0.25])
    }

    func testMissingAmbiguousOrUnidentifiableProcessDoesNotCreateAXApplication() {
        for applications in [[], [process(terminated: true)], [process(), process(pid: 456)],
                             [process(launched: nil)]] {
            let stub = ExposureEnvironmentStub()
            stub.applications = applications
            assertCommandError(.accessibilitySetupUnavailable) {
                try SystemAccessibilityExposureClient(environment: stub.environment)
            }
            XCTAssertEqual(stub.attributes.events, ["applications com.microsoft.teams2"])
            XCTAssertTrue(stub.attributes.writes.isEmpty)
        }
    }

    func testGenerationChecksPinnedProcessAndDistinguishesGoneReplacedAndUnknown() throws {
        let cases: [(AccessibilityExposureProcess?, Bool?)] = [
            (process(), true), (nil, false), (process(terminated: true), false),
            (process(launched: Date(timeIntervalSince1970: 20)), false), (process(launched: nil), nil)
        ]
        for (current, expected) in cases {
            let stub = ExposureEnvironmentStub()
            let client = try SystemAccessibilityExposureClient(environment: stub.environment)
            stub.current = current
            stub.applications = [process(pid: 456)]
            stub.attributes.events = []
            XCTAssertEqual(client.sameGeneration(), expected)
            XCTAssertEqual(stub.attributes.events, ["process 123"])
            XCTAssertEqual(client.launched, Date(timeIntervalSince1970: 10))
        }
    }

    func testReadAcceptsBothNativeBooleanValues() throws {
        let stub = ExposureEnvironmentStub()
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        stub.attributes.events = []
        stub.attributes.value = kCFBooleanTrue
        XCTAssertEqual(client.read(), true)
        stub.attributes.value = kCFBooleanFalse
        XCTAssertEqual(client.read(), false)
        XCTAssertEqual(stub.attributes.events, ["read AXEnhancedUserInterface", "read AXEnhancedUserInterface"])
        XCTAssertTrue(stub.attributes.writes.isEmpty)
    }

    func testReadRejectsFailedMissingAndNonBooleanValues() throws {
        let cases: [(CFTypeRef?, AXError)] = [
            (kCFBooleanTrue, .failure), (nil, .success), ("true" as CFString, .success),
            (NSNumber(value: 1), .success), (AXUIElementCreateApplication(456), .success)
        ]
        for (value, error) in cases {
            let stub = ExposureEnvironmentStub()
            let client = try SystemAccessibilityExposureClient(environment: stub.environment)
            stub.attributes.value = value
            stub.attributes.readError = error
            XCTAssertNil(client.read())
            XCTAssertTrue(stub.attributes.writes.isEmpty)
        }
    }

    func testWritesExactNativeBooleanValuesToPinnedApplication() throws {
        let stub = ExposureEnvironmentStub()
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        stub.attributes.writeError = .failure
        client.write(true)
        client.write(false)
        XCTAssertEqual(stub.attributes.writes.map(\.0), ["AXEnhancedUserInterface", "AXEnhancedUserInterface"])
        let values = stub.attributes.writes.map(\.1)
        XCTAssertEqual(values.map(CFGetTypeID), [CFBooleanGetTypeID(), CFBooleanGetTypeID()])
        XCTAssertTrue(CFEqual(values[0], kCFBooleanTrue))
        XCTAssertTrue(CFEqual(values[1], kCFBooleanFalse))
    }

    func testAppliedWriteWithNativeErrorStillUsesReadbackAndRestoresOriginalValue() throws {
        let stub = ExposureEnvironmentStub()
        stub.attributes.writeError = .failure
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        var exposure: TeamsAccessibilityExposure? = try TeamsAccessibilityExposure(client: client)
        XCTAssertTrue(CFEqual(try XCTUnwrap(stub.attributes.value), kCFBooleanTrue))
        XCTAssertTrue(exposure!.restore())
        XCTAssertTrue(CFEqual(try XCTUnwrap(stub.attributes.value), kCFBooleanFalse))
        exposure = nil
        XCTAssertEqual(stub.attributes.writes.count, 2)
        XCTAssertEqual(stub.attributes.timeouts.last, 0.25)
    }

    func testSuccessfulSetterWithoutAppliedValueTimesOutAndDoesNotRetryWrite() throws {
        let stub = ExposureEnvironmentStub()
        stub.attributes.applyWrites = false
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        assertCommandError(.accessibilitySetupUnavailable) {
            try TeamsAccessibilityExposure(client: client)
        }
        XCTAssertEqual(stub.attributes.writes.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(stub.attributes.value), kCFBooleanFalse))
        XCTAssertEqual(stub.uptime, 0.4, accuracy: 0.000001)
        XCTAssertFalse(stub.waits.isEmpty)
        XCTAssertTrue(stub.waits.allSatisfy { $0 > 0 && $0 <= 0.025 })
        XCTAssertEqual(stub.attributes.timeouts.last, 0.25)
    }

    func testReadinessOutcomesRestorePerMessageTimeoutWithoutWrites() throws {
        for expected in [AccessibilityExposureReadiness.Result.confirmed, .processGone, .unavailable, .timedOut] {
            let stub = ExposureEnvironmentStub()
            let client = try SystemAccessibilityExposureClient(environment: stub.environment)
            switch expected {
            case .confirmed: stub.attributes.value = kCFBooleanTrue
            case .processGone: stub.current = nil
            case .unavailable: stub.current = process(launched: nil)
            case .timedOut: break
            }
            XCTAssertEqual(client.waitForValue(true), expected)
            XCTAssertEqual(stub.attributes.timeouts.last, 0.25)
            XCTAssertTrue(stub.attributes.timeouts.allSatisfy { $0 > 0 && $0 <= 0.25 })
            XCTAssertTrue(stub.attributes.writes.isEmpty)
            if expected == .timedOut {
                XCTAssertEqual(stub.uptime, 0.4, accuracy: 0.000001)
                XCTAssertTrue(stub.attributes.timeouts.contains { $0 < 0.25 })
            }
        }
    }

    func testProcessReplacementDuringReadCannotConfirmReadiness() throws {
        let stub = ExposureEnvironmentStub()
        let client = try SystemAccessibilityExposureClient(environment: stub.environment)
        stub.attributes.value = kCFBooleanTrue
        stub.attributes.onRead = { [weak stub] in
            stub?.current = self.process(launched: Date(timeIntervalSince1970: 20))
        }
        XCTAssertEqual(client.waitForValue(true), .processGone)
        XCTAssertEqual(stub.attributes.timeouts.last, 0.25)
        XCTAssertTrue(stub.attributes.writes.isEmpty)
        XCTAssertTrue(stub.waits.isEmpty)
    }

    private func process(pid: pid_t = 123, terminated: Bool = false,
                         launched: Date? = Date(timeIntervalSince1970: 10)) -> AccessibilityExposureProcess {
        AccessibilityExposureProcess(pid: pid, isTerminated: terminated, launchDate: launched)
    }
}

private final class ExposureEnvironmentStub {
    let attributes = AccessibilityAttributeStub()
    var applications = [AccessibilityExposureProcess(pid: 123, isTerminated: false,
                                                     launchDate: Date(timeIntervalSince1970: 10))]
    var current: AccessibilityExposureProcess? = AccessibilityExposureProcess(
        pid: 123, isTerminated: false, launchDate: Date(timeIntervalSince1970: 10)
    )
    var uptime: TimeInterval = 0
    private(set) var waits: [TimeInterval] = []

    var environment: AccessibilityExposureEnvironment {
        AccessibilityExposureEnvironment(runningApplications: { identifier in
            self.attributes.events.append("applications \(identifier)")
            return self.applications
        }, runningApplication: { pid in
            self.attributes.events.append("process \(pid)")
            return self.current
        }, attributes: attributes.client, now: { self.uptime }, wait: { duration in
            self.waits.append(duration)
            self.uptime += duration
        })
    }
}
