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
