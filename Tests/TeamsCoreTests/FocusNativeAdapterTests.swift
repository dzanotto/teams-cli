import AppKit
import ApplicationServices
import XCTest
@testable import TeamsCore

final class FocusNativeAdapterTests: XCTestCase {
    func testActivationSubscriptionForwardsProcessAndUnknownPayloads() {
        let center = NotificationCenter()
        let recorder = ActivationRecorder()
        let observation = FocusMonitoringEnvironment.observeActivation(in: center, handler: recorder.record)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: "invalid"])
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertEqual(recorder.values, [NSRunningApplication.current.processIdentifier, nil, nil])
        observation.cancel()
    }

    func testActivationCancellationRemovesSubscriptionExactlyOnce() {
        let center = NotificationCenter()
        let recorder = ActivationRecorder()
        var observation: FocusObservation? = FocusMonitoringEnvironment.observeActivation(
            in: center, handler: recorder.record
        )
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        observation?.cancel()
        observation?.cancel()
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        observation = nil
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(recorder.values.count, 1)
    }

    func testActivationDeinitUnsubscribesAndReleasesHandler() {
        let center = NotificationCenter()
        var recorder: ActivationRecorder? = ActivationRecorder()
        let currentRecorder = { [weak recorder] in recorder }
        var observation: FocusObservation? = FocusMonitoringEnvironment.observeActivation(
            in: center, handler: recorder!.record
        )
        recorder = nil
        XCTAssertNotNil(observation)
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(currentRecorder()?.values.count, 1)
        observation = nil
        XCTAssertNil(currentRecorder())
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    func testFailedOrMissingObserverStopsBeforeRegistration() {
        for (error, hasObserver): (AXError, Bool) in [(.failure, true), (.success, false)] {
            let stub = WindowObserverStub()
            stub.creationError = error
            stub.hasObserver = hasObserver
            let observation = stub.client.observe(pid: 123) { _ in XCTFail("No subscription exists") }
            XCTAssertNil(observation)
            XCTAssertEqual(stub.events, ["application", "create"])
            XCTAssertNil(stub.observer)
            XCTAssertNil(stub.callback)
        }
    }

    func testRegistrationFailureReleasesObserverAndCallbackWithoutInstallingSource() {
        let stub = WindowObserverStub()
        stub.registrationError = .notificationUnsupported
        stub.onRegister = { XCTAssertNotNil(stub.callback) }
        let observation = stub.client.observe(pid: 123) { _ in XCTFail("No registered notification") }
        XCTAssertNil(observation)
        XCTAssertEqual(stub.events, ["application", "create", "register"])
        XCTAssertNil(stub.observer)
        XCTAssertNil(stub.callback)
        stub.onRegister = nil
    }

    func testRegisteredCallbackDeliversExactElementAndIgnoresMissingContext() throws {
        let stub = WindowObserverStub()
        var received: [AXUIElement] = []
        let observation = try XCTUnwrap(stub.client.observe(pid: 123) { received.append($0) })
        XCTAssertEqual(stub.events, ["application", "create", "register", "add"])
        stub.deliver()
        FocusWindowCallback.deliver(element: stub.window, context: nil)
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(received.first), stub.window))
        observation.cancel()
    }

    func testCallbackIsAliveDuringRegistrationAndSourceInstallation() throws {
        let stub = WindowObserverStub()
        var deliveries = 0
        stub.onRegister = { stub.deliver() }
        stub.onAddSource = { stub.deliver() }
        let observation = try XCTUnwrap(stub.client.observe(pid: 123) { _ in deliveries += 1 })
        XCTAssertEqual(deliveries, 2)
        observation.cancel()
        stub.onRegister = nil
        stub.onAddSource = nil
    }

    func testCancellationRetainsContextThroughOrderedCleanupThenReleasesOwnership() throws {
        let stub = WindowObserverStub()
        var deliveries = 0
        var observation: FocusObservation? = try XCTUnwrap(
            stub.client.observe(pid: 123) { _ in deliveries += 1 }
        )
        stub.onRemoveSource = {
            XCTAssertNotNil(stub.observer)
            XCTAssertNotNil(stub.callback)
            stub.deliver()
            observation?.cancel() // Reentrant cleanup must not unregister twice.
        }
        stub.onUnregister = {
            XCTAssertNotNil(stub.observer)
            XCTAssertNotNil(stub.callback)
            stub.deliver()
        }
        observation?.cancel()
        observation?.cancel()
        observation = nil
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(stub.events, ["application", "create", "register", "add", "remove", "unregister"])
        XCTAssertNil(stub.observer)
        XCTAssertNil(stub.callback)
        stub.onRemoveSource = nil
        stub.onUnregister = nil
    }

    func testWindowObservationDeinitPerformsCleanupWithLiveCallback() throws {
        let stub = WindowObserverStub()
        var deliveries = 0
        var observation: FocusObservation? = try XCTUnwrap(
            stub.client.observe(pid: 123) { _ in deliveries += 1 }
        )
        stub.onRemoveSource = { stub.deliver() }
        stub.onUnregister = { stub.deliver() }
        XCTAssertNotNil(observation)
        XCTAssertNotNil(stub.observer)
        XCTAssertNotNil(stub.callback)
        observation = nil
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(Array(stub.events.suffix(2)), ["remove", "unregister"])
        XCTAssertNil(stub.observer)
        XCTAssertNil(stub.callback)
        stub.onRemoveSource = nil
        stub.onUnregister = nil
    }
}

private final class ActivationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [pid_t?] = []

    var values: [pid_t?] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ pid: pid_t?) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(pid)
    }
}

private final class WindowObserverToken {}

/// Only opaque local elements and an unretained callback context are used; no AX subscription is created.
private final class WindowObserverStub {
    let application = AXUIElementCreateApplication(10)
    let window = AXUIElementCreateApplication(11)
    var creationError = AXError.success
    var registrationError = AXError.success
    var hasObserver = true
    var onRegister: (() -> Void)?
    var onAddSource: (() -> Void)?
    var onRemoveSource: (() -> Void)?
    var onUnregister: (() -> Void)?
    private(set) var events: [String] = []
    private(set) weak var observer: WindowObserverToken?
    private(set) weak var callback: FocusWindowCallback?
    private var context: UnsafeMutableRawPointer?

    func deliver() {
        // Never dereference a stale raw context if a lifetime regression occurs.
        guard callback != nil else {
            XCTFail("Callback was released while native delivery was still possible")
            return
        }
        FocusWindowCallback.deliver(element: window, context: context)
    }

    var client: FocusWindowObserverClient<WindowObserverToken> {
        FocusWindowObserverClient(makeApplication: { pid in
            XCTAssertEqual(pid, 123)
            self.events.append("application")
            return self.application
        }, create: { pid in
            XCTAssertEqual(pid, 123)
            self.events.append("create")
            let token = self.hasObserver ? WindowObserverToken() : nil
            self.observer = token
            return (token, self.creationError)
        }, register: { observer, application, context in
            XCTAssertTrue(observer === self.observer)
            XCTAssertTrue(CFEqual(application, self.application))
            self.events.append("register")
            self.context = context
            self.callback = Unmanaged<FocusWindowCallback>.fromOpaque(context).takeUnretainedValue()
            self.onRegister?()
            return self.registrationError
        }, addSource: { observer in
            XCTAssertTrue(observer === self.observer)
            self.events.append("add")
            self.onAddSource?()
        }, removeSource: { observer in
            XCTAssertTrue(observer === self.observer)
            self.events.append("remove")
            self.onRemoveSource?()
        }, unregister: { observer, application in
            XCTAssertTrue(observer === self.observer)
            XCTAssertTrue(CFEqual(application, self.application))
            self.events.append("unregister")
            self.onUnregister?()
            self.context = nil
        })
    }
}
