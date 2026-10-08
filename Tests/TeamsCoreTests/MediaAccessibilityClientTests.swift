import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class MediaAccessibilityClientTests: XCTestCase {
    func testPressEligibilityRequiresEnabledAttributeBeforeReadingActions() {
        for value: CFTypeRef? in [nil, kCFBooleanFalse, "true" as CFString] {
            let stub = MediaNativeReadStub()
            stub.attribute = (value, .success)
            XCTAssertFalse(stub.client.canPress(stub.element))
            XCTAssertEqual(stub.events, ["timeout", kAXEnabledAttribute])
        }
    }

    func testFailedEnabledReadCannotAuthorizePressEvenWhenItReturnsTrue() {
        let stub = MediaNativeReadStub()
        stub.attribute = (kCFBooleanTrue, .cannotComplete)
        XCTAssertFalse(stub.client.canPress(stub.element))
        XCTAssertEqual(stub.events, ["timeout", kAXEnabledAttribute])
    }

    func testPressEligibilityRejectsMissingMalformedOrUnsupportedActions() {
        for actions: CFArray? in [nil, [] as CFArray, ["AXShowMenu"] as CFArray, [1] as CFArray] {
            let stub = MediaNativeReadStub()
            stub.actions = (actions, .success)
            XCTAssertFalse(stub.client.canPress(stub.element))
            XCTAssertEqual(stub.events, ["timeout", kAXEnabledAttribute, "actions"])
        }
    }

    func testFailedActionReadCannotAuthorizePressEvenWhenPressIsListed() {
        let stub = MediaNativeReadStub()
        stub.actions = ([kAXPressAction] as CFArray, .cannotComplete)
        XCTAssertFalse(stub.client.canPress(stub.element))
    }

    func testEnabledControlWithPressActionIsEligible() {
        let stub = MediaNativeReadStub()
        stub.actions = (["AXShowMenu", kAXPressAction] as CFArray, .success)
        XCTAssertTrue(stub.client.canPress(stub.element))
        XCTAssertEqual(stub.events, ["timeout", kAXEnabledAttribute, "actions"])
    }

    func testAttributeReadSetsTimeoutAndPreservesSuccessfulValue() throws {
        let stub = MediaNativeReadStub()
        let expected = "Mute mic" as CFString
        stub.attribute = (expected, .success)
        let actual = try XCTUnwrap(stub.client.value(stub.element, kAXDescriptionAttribute))
        XCTAssertTrue(CFEqual(actual, expected))
        XCTAssertEqual(stub.events, ["timeout", kAXDescriptionAttribute])
    }

    func testMissingOrFailedAttributeReadReturnsNoValue() {
        for result: (CFTypeRef?, AXError) in [(nil, .success), ("stale" as CFString, .noValue),
                                            (nil, .attributeUnsupported)] {
            let stub = MediaNativeReadStub()
            stub.attribute = result
            XCTAssertNil(stub.client.value(stub.element, kAXDescriptionAttribute))
            XCTAssertEqual(stub.events, ["timeout", kAXDescriptionAttribute])
        }
    }

    func testGenerationRequiresLaunchDateAndPreservesApplicationIdentity() {
        let stub = MediaNativeReadStub()
        let expected = MediaProcessGeneration(pid: stub.application.processIdentifier, launched: stub.expectedLaunch)
        XCTAssertEqual(stub.client.generation(of: stub.application), expected)
        stub.launched = nil
        XCTAssertNil(stub.client.generation(of: stub.application))
        XCTAssertEqual(stub.events, ["launch", "launch"])
    }

    func testMissingProcessStopsBeforeReadingItsProperties() {
        let stub = MediaNativeReadStub()
        stub.exists = false
        XCTAssertFalse(stub.client.processMatches(pid: 123, launched: stub.expectedLaunch))
        XCTAssertEqual(stub.events, ["lookup"])
    }

    func testTerminatedProcessCannotMatchAndDoesNotReadLaunchDate() {
        let stub = MediaNativeReadStub()
        stub.terminated = true
        XCTAssertFalse(stub.client.processMatches(pid: 123, launched: stub.expectedLaunch))
        XCTAssertEqual(stub.events, ["lookup", "terminated"])
    }

    func testReusedOrUnknownProcessGenerationCannotMatch() {
        for launched: Date? in [nil, Date(timeIntervalSince1970: 200)] {
            let stub = MediaNativeReadStub()
            stub.launched = launched
            XCTAssertFalse(stub.client.processMatches(pid: 123, launched: stub.expectedLaunch))
            XCTAssertEqual(stub.events, ["lookup", "terminated", "launch"])
        }
    }

    func testMatchingLiveProcessIsAcceptedAndEachCheckLooksUpProcessAgain() {
        let stub = MediaNativeReadStub()
        let client = stub.client
        XCTAssertTrue(client.processMatches(pid: 123, launched: stub.expectedLaunch))
        stub.launched = stub.expectedLaunch.addingTimeInterval(1)
        XCTAssertFalse(client.processMatches(pid: 123, launched: stub.expectedLaunch))
        XCTAssertEqual(stub.events, ["lookup", "terminated", "launch", "lookup", "terminated", "launch"])
    }
}

/// NSRunningApplication.current is only an identity token; all process properties and AX reads are scripted.
private final class MediaNativeReadStub {
    let element = AXUIElementCreateApplication(10)
    let application = NSRunningApplication.current
    let expectedLaunch = Date(timeIntervalSince1970: 100)
    var exists = true
    var terminated = false
    var launched: Date? = Date(timeIntervalSince1970: 100)
    var attribute: (CFTypeRef?, AXError) = (kCFBooleanTrue, .success)
    var actions: (CFArray?, AXError) = ([kAXPressAction] as CFArray, .success)
    private(set) var events: [String] = []

    var client: SystemMediaAccessibilityClient {
        SystemMediaAccessibilityClient(environment: MediaAccessibilityEnvironment(runningApplication: { pid in
            XCTAssertEqual(pid, 123)
            self.events.append("lookup")
            return self.exists ? self.application : nil
        }, isTerminated: { application in
            XCTAssertTrue(application === self.application)
            self.events.append("terminated")
            return self.terminated
        }, launchDate: { application in
            XCTAssertTrue(application === self.application)
            self.events.append("launch")
            return self.launched
        }, setMessagingTimeout: { element, timeout in
            XCTAssertTrue(CFEqual(element, self.element))
            XCTAssertEqual(timeout, 0.25)
            self.events.append("timeout")
        }, copyAttribute: { element, name in
            XCTAssertTrue(CFEqual(element, self.element))
            self.events.append(name)
            return self.attribute
        }, copyActionNames: { element in
            XCTAssertTrue(CFEqual(element, self.element))
            self.events.append("actions")
            return self.actions
        }))
    }
}
