import Foundation
import XCTest
@testable import TeamsCore

final class ScriptedExposureClient: AccessibilityExposureClient {
    var value: Bool? = false
    var generation: Bool? = true
    var applyWrites = true
    var waitResults: [AccessibilityExposureReadiness.Result] = []
    var onRead: (() -> Void)?
    var onWrite: ((Bool) -> Void)?
    var onWait: ((Bool) -> Void)?
    var record: (String) -> Void = { _ in }
    private(set) var writes: [Bool] = []
    private(set) var readCount = 0

    func sameGeneration() -> Bool? { generation }

    func read() -> Bool? {
        readCount += 1
        record("read")
        onRead?()
        return value
    }

    func write(_ value: Bool) {
        writes.append(value)
        record("write \(value)")
        if applyWrites { self.value = value }
        onWrite?(value)
    }

    func waitForValue(_ expected: Bool) -> AccessibilityExposureReadiness.Result {
        record("verify \(expected)")
        onWait?(expected)
        if !waitResults.isEmpty { return waitResults.removeFirst() }
        return value == expected ? .confirmed : .timedOut
    }
}

func assertCommandError<T>(
    _ expected: MicrophoneCommandError,
    file: StaticString = #filePath, line: UInt = #line,
    _ operation: () throws -> T
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        guard let actual = error as? MicrophoneCommandError else {
            return XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

func temporaryCommandDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teams-cli-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

final class LifecycleFocus: MediaCommandFocus {
    var result: Bool? = true
    var record: (String) -> Void = { _ in }
    var onStop: (() -> Void)?

    func preserved() -> Bool? {
        record("focus.read")
        return result
    }

    func stop() {
        record("focus.stop")
        onStop?()
    }
}

final class CommandLifecycleHarness {
    enum Failure: Error { case operation }
    let directory: URL
    var path: String { directory.appendingPathComponent("command.lock").path }
    let client = ScriptedExposureClient()
    let focus = LifecycleFocus()
    var trusted = true
    var operationError = false
    var events: [String] = []

    init() throws {
        directory = try temporaryCommandDirectory()
        client.record = { [weak self] in self?.events.append($0) }
        focus.record = { [weak self] in self?.events.append($0) }
    }

    var environment: MediaCommandEnvironment<LifecycleFocus> {
        MediaCommandEnvironment(isTrusted: {
            self.events.append("permission")
            return self.trusted
        }, acquireLock: {
            self.events.append("lock")
            return try MediaCommandLock(path: self.path)
        }, makeFocus: {
            self.events.append("focus.start")
            return self.focus
        }, makeExposure: {
            self.events.append("expose")
            return try TeamsAccessibilityExposure(client: self.client)
        })
    }

    func perform() throws -> Int {
        try TeamsMediaCommandSupport.perform({ _ in
            self.events.append("operation")
            if self.operationError { throw Failure.operation }
            return 42
        }, environment: environment, onFinalization: { result, _, _ in
            self.events.append("finalize")
            return result
        })
    }

    func assertLocked(file: StaticString = #filePath, line: UInt = #line) {
        assertCommandError(.commandInProgress, file: file, line: line) { try MediaCommandLock(path: path) }
    }

    func assertUnlocked(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try MediaCommandLock(path: path).release(), file: file, line: line)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
