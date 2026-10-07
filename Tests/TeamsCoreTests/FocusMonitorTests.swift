import ApplicationServices
import XCTest
@testable import TeamsCore

final class FocusMonitorTests: XCTestCase {
    func testUnchangedFocusRemainsConfirmedAcrossRepeatedChecks() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        XCTAssertEqual(monitor.preserved(), true)
        XCTAssertEqual(monitor.preserved(), true)
        XCTAssertEqual(client.windowPIDs, [123])
        XCTAssertEqual(client.events.filter { $0 == "activation.start" }.count, 1)
        XCTAssertEqual(client.captureCount, 4) // Baseline, post-registration, and two checks.
    }

    func testChangedApplicationOrWindowRemainsChangedAfterReturning() {
        for changed in [focus(pid: 456), focus(window: 20)] {
            let client = FocusMonitoringStub()
            let monitor = FocusMonitor(environment: client.environment)
            client.current = changed
            XCTAssertEqual(monitor.preserved(), false)
            client.current = focus()
            XCTAssertEqual(monitor.preserved(), false)
        }
    }

    func testActivationNotificationsCatchSwitchAwayAndBackBetweenSnapshots() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.activationHandler?(456)
        client.activationHandler?(123)
        // Both current snapshots still show the original foreground application.
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testSameApplicationActivationDoesNotInventAChange() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.activationHandler?(123)
        XCTAssertEqual(monitor.preserved(), true)
    }

    func testUnknownActivationLatchesInconclusiveEvidence() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.activationHandler?(nil)
        XCTAssertNil(monitor.preserved())
        client.activationHandler?(123)
        XCTAssertNil(monitor.preserved())
    }

    func testWindowNotificationRetainsTransientChangeEvenWhenCurrentWindowHasReturned() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.windowHandler?(AXUIElementCreateApplication(20))
        client.windowHandler?(AXUIElementCreateApplication(10))
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testSameWindowNotificationWithMatchingCurrentFocusRemainsConfirmed() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.windowHandler?(AXUIElementCreateApplication(10))
        XCTAssertEqual(monitor.preserved(), true)
    }

    func testApplicationOrUnreadableWindowNotificationCannotBeDismissedAsUnchanged() {
        for role in ["AXApplication", "AXUnknown", nil] {
            let client = FocusMonitoringStub()
            let monitor = FocusMonitor(environment: client.environment)
            client.notificationRole = role
            client.windowHandler?(AXUIElementCreateApplication(10))
            XCTAssertEqual(monitor.preserved(), false)
        }
    }

    func testWindowNotificationAlsoChecksCurrentFocus() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.current = focus(window: 20)
        client.windowHandler?(AXUIElementCreateApplication(10))
        client.current = focus()
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testWindowNotificationWithUnavailableCurrentFocusLatchesInconclusiveEvidence() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.current = MonitoredFocus(pid: 123, window: nil)
        client.windowHandler?(AXUIElementCreateApplication(10))
        client.current = focus()
        XCTAssertNil(monitor.preserved())
    }

    func testIncompleteBaselineSkipsWindowRegistrationAndNeverBecomesConfirmed() {
        for baseline in [MonitoredFocus(pid: nil, window: nil), MonitoredFocus(pid: 123, window: nil),
                         MonitoredFocus(pid: nil, window: AXUIElementCreateApplication(10))] {
            let client = FocusMonitoringStub()
            client.current = baseline
            let monitor = FocusMonitor(environment: client.environment)
            XCTAssertNil(monitor.preserved())
            client.current = focus()
            XCTAssertNil(monitor.preserved())
            XCTAssertTrue(client.windowPIDs.isEmpty)
            monitor.stop()
            XCTAssertEqual(client.events.filter { $0.hasSuffix(".stop") }, ["activation.stop"])
        }
    }

    func testIncompleteCurrentSnapshotCannotBeRepairedByLaterMatchingSnapshot() {
        for current in [MonitoredFocus(pid: nil, window: nil), MonitoredFocus(pid: 123, window: nil)] {
            let client = FocusMonitoringStub()
            let monitor = FocusMonitor(environment: client.environment)
            client.current = current
            XCTAssertNil(monitor.preserved())
            client.current = focus()
            XCTAssertNil(monitor.preserved())
        }
    }

    func testDifferentApplicationIsAConfirmedChangeEvenWithoutItsWindow() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.current = MonitoredFocus(pid: 456, window: nil)
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testFailedWindowRegistrationStaysInconclusiveAndCleansUpActivationObserver() {
        let client = FocusMonitoringStub()
        client.windowRegistrationFails = true
        let monitor = FocusMonitor(environment: client.environment)
        XCTAssertNil(monitor.preserved())
        XCTAssertEqual(client.windowPIDs, [123])
        monitor.stop()
        XCTAssertEqual(client.events.filter { $0.hasSuffix(".stop") }, ["activation.stop"])
        XCTAssertNil(client.activationHandler)
    }

    func testSnapshotAfterRegistrationDetectsInitializationChanges() {
        for changed in [focus(pid: 456), focus(window: 20), MonitoredFocus(pid: 123, window: nil)] {
            let client = FocusMonitoringStub()
            client.onWindowRegistration = { [weak client] in client?.current = changed }
            let monitor = FocusMonitor(environment: client.environment)
            client.current = focus()
            XCTAssertEqual(monitor.preserved(), changed.window == nil ? nil : false)
        }
    }

    func testActivationDuringRegistrationIsObservedBeforeFirstPoll() {
        let client = FocusMonitoringStub()
        client.onActivationRegistration = { [weak client] in
            client?.activationHandler?(456)
            client?.activationHandler?(123)
        }
        let monitor = FocusMonitor(environment: client.environment)
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testWindowEventDuringRegistrationIsObservedBeforeFirstPoll() {
        let client = FocusMonitoringStub()
        client.onWindowRegistration = { [weak client] in
            client?.windowHandler?(AXUIElementCreateApplication(20))
        }
        let monitor = FocusMonitor(environment: client.environment)
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testConfirmedChangeTakesPrecedenceOverInconclusiveEvidenceInEitherOrder() {
        for activations: [pid_t?] in [[nil, 456], [456, nil]] {
            let client = FocusMonitoringStub()
            let monitor = FocusMonitor(environment: client.environment)
            for pid in activations { client.activationHandler?(pid) }
            client.current = MonitoredFocus(pid: nil, window: nil)
            XCTAssertEqual(monitor.preserved(), false)
            client.current = focus()
            XCTAssertEqual(monitor.preserved(), false)
        }
    }

    func testConfirmedActivationChangeOverridesMissingBaselineWindowOrFailedRegistration() {
        for missingWindow in [true, false] {
            let client = FocusMonitoringStub()
            if missingWindow { client.current = MonitoredFocus(pid: 123, window: nil) }
            else { client.windowRegistrationFails = true }
            let monitor = FocusMonitor(environment: client.environment)
            client.activationHandler?(456)
            XCTAssertEqual(monitor.preserved(), false)
        }
    }

    func testActivationCannotEstablishChangeWhenBaselineApplicationIsUnknown() {
        let client = FocusMonitoringStub()
        client.current = MonitoredFocus(pid: nil, window: nil)
        let monitor = FocusMonitor(environment: client.environment)
        client.activationHandler?(456)
        XCTAssertNil(monitor.preserved())
    }

    func testQueuedNotificationsAreDrainedBeforeCurrentSnapshotAndResult() {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        client.events = []
        client.onDrain = { [weak client] in
            client?.activationHandler?(456)
            client?.activationHandler?(123)
            client?.windowHandler?(AXUIElementCreateApplication(20))
        }
        XCTAssertEqual(monitor.preserved(), false)
        XCTAssertEqual(client.events, ["drain", "role", "capture", "capture"])
    }

    func testStopCancelsBothObserversOnceAndPreventsFurtherSampling() {
        let client = FocusMonitoringStub()
        var monitor: FocusMonitor? = FocusMonitor(environment: client.environment)
        client.events = []
        monitor?.stop()
        monitor?.stop()
        XCTAssertNil(monitor?.preserved())
        monitor = nil
        XCTAssertEqual(client.events, ["activation.stop", "window.stop"])
        XCTAssertNil(client.activationHandler)
        XCTAssertNil(client.windowHandler)
        XCTAssertNil(client.activationObservation)
        XCTAssertNil(client.windowObservation)
    }

    func testDeinitCancelsObserversWithoutExplicitStop() {
        let client = FocusMonitoringStub()
        var monitor: FocusMonitor? = FocusMonitor(environment: client.environment)
        XCTAssertNotNil(monitor)
        client.events = []
        monitor = nil
        XCTAssertEqual(client.events, ["activation.stop", "window.stop"])
        XCTAssertNil(client.activationObservation)
        XCTAssertNil(client.windowObservation)
    }

    func testRetainedCallbacksDoNotRetainMonitorOrReadAfterItsDeinit() throws {
        let client = FocusMonitoringStub()
        var monitor: FocusMonitor? = FocusMonitor(environment: client.environment)
        let activation = try XCTUnwrap(client.activationHandler)
        let window = try XCTUnwrap(client.windowHandler)
        XCTAssertNotNil(monitor)
        monitor = nil
        XCTAssertEqual(Array(client.events.suffix(2)), ["activation.stop", "window.stop"])
        client.events = []
        activation(456)
        window(AXUIElementCreateApplication(20))
        XCTAssertTrue(client.events.isEmpty)
    }

    func testConcurrentActivationNotificationsPreserveChangedAndInconclusiveEvidence() throws {
        let client = FocusMonitoringStub()
        let monitor = FocusMonitor(environment: client.environment)
        let activation = try XCTUnwrap(client.activationHandler)
        // Only the Sendable notification callback crosses threads; monitor polling stays here.
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            activation(index % 3 == 0 ? nil : (index % 3 == 1 ? 456 : 123))
        }
        XCTAssertEqual(monitor.preserved(), false)
    }

    func testObservationCancellationIsIdempotentIncludingReentrantCancellationAndDeinit() {
        var count = 0
        var observation: FocusObservation?
        observation = FocusObservation {
            count += 1
            observation?.cancel()
        }
        observation?.cancel()
        observation?.cancel()
        observation = nil
        XCTAssertEqual(count, 1)
    }

    func testObservationDeinitCancelsWhenNotExplicitlyCancelled() {
        var count = 0
        var observation: FocusObservation? = FocusObservation { count += 1 }
        XCTAssertNotNil(observation)
        observation = nil
        XCTAssertEqual(count, 1)
    }

    private func focus(pid: pid_t = 123, window: pid_t = 10) -> MonitoredFocus {
        MonitoredFocus(pid: pid, window: AXUIElementCreateApplication(window))
    }
}

/// Elements are opaque local identity tokens; no native focus reads or subscriptions occur.
private final class FocusMonitoringStub {
    var current = MonitoredFocus(pid: 123, window: AXUIElementCreateApplication(10))
    var notificationRole: String? = "AXWindow"
    var windowRegistrationFails = false
    var activationHandler: (@Sendable (pid_t?) -> Void)?
    var windowHandler: ((AXUIElement) -> Void)?
    var onActivationRegistration: (() -> Void)?
    var onWindowRegistration: (() -> Void)?
    var onDrain: (() -> Void)?
    var events: [String] = []
    private(set) var windowPIDs: [pid_t] = []
    private(set) var captureCount = 0
    private(set) weak var activationObservation: FocusObservation?
    private(set) weak var windowObservation: FocusObservation?

    var environment: FocusMonitoringEnvironment {
        FocusMonitoringEnvironment(capture: {
            self.events.append("capture")
            self.captureCount += 1
            return self.current
        }, observeActivation: { [self] handler in
            self.events.append("activation.start")
            self.activationHandler = handler
            self.onActivationRegistration?()
            let observation = FocusObservation { [weak self] in
                self?.events.append("activation.stop")
                self?.activationHandler = nil
            }
            self.activationObservation = observation
            return observation
        }, observeWindow: { [self] pid, handler in
            self.events.append("window.start")
            self.windowPIDs.append(pid)
            guard !self.windowRegistrationFails else { return nil }
            self.windowHandler = handler
            self.onWindowRegistration?()
            let observation = FocusObservation { [weak self] in
                self?.events.append("window.stop")
                self?.windowHandler = nil
            }
            self.windowObservation = observation
            return observation
        }, role: { _ in
            self.events.append("role")
            return self.notificationRole
        }, drainNotifications: {
            self.events.append("drain")
            self.onDrain?()
        })
    }
}
