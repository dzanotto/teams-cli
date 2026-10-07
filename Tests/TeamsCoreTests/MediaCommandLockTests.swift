import Darwin
import Foundation
import XCTest
@testable import TeamsCore

final class MediaCommandLockTests: XCTestCase {
    func testDefaultPathRemainsSharedWithOlderMicrophoneCommands() {
        XCTAssertEqual(MediaCommandLock.defaultPath, "/tmp/teams-cli-microphone-\(getuid()).lock")
    }

    func testCreatesPrivateRegularFileAndRejectsSecondAcquisition() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command.lock").path
        let held = try MediaCommandLock(path: path)
        defer { held.release() }
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_uid, getuid())
        XCTAssertEqual(metadata.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(metadata.st_mode & mode_t(0o077), 0)
        assertCommandError(.commandInProgress) { try MediaCommandLock(path: path) }
    }

    func testReleaseRetainsInodeAndIsIdempotentEvenAfterAnotherLockAcquires() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command.lock").path
        let first = try MediaCommandLock(path: path)
        var before = stat()
        XCTAssertEqual(lstat(path, &before), 0)
        first.release()
        let second = try MediaCommandLock(path: path)
        defer { second.release() }
        first.release()
        var after = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        assertCommandError(.commandInProgress) { try MediaCommandLock(path: path) }
    }

    func testDeinitReleasesLock() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command.lock").path
        var held: MediaCommandLock? = try MediaCommandLock(path: path)
        XCTAssertNotNil(held)
        assertCommandError(.commandInProgress) { try MediaCommandLock(path: path) }
        held = nil
        XCTAssertNoThrow(try MediaCommandLock(path: path).release())
    }

    func testSymlinksAreRejectedWithoutChangingTheirTarget() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let original = Data("leave unchanged".utf8)
        try original.write(to: target)
        let path = directory.appendingPathComponent("command.lock").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        assertCommandError(.lockUnavailable) { try MediaCommandLock(path: path) }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testNonRegularFilesAndInsecurePermissionsAreRejected() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(fifo, mode_t(0o600)), 0)
        assertCommandError(.lockUnavailable) { try MediaCommandLock(path: fifo) }
        let path = directory.appendingPathComponent("command.lock").path
        for mode in [0o640, 0o606] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
            XCTAssertEqual(chmod(path, mode_t(mode)), 0)
            assertCommandError(.lockUnavailable) { try MediaCommandLock(path: path) }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func testMissingParentDirectoryReportsLockUnavailable() throws {
        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("missing/command.lock").path
        assertCommandError(.lockUnavailable) { try MediaCommandLock(path: path) }
    }

    func testLockContendsAcrossProcesses() throws {
        let environment = ProcessInfo.processInfo.environment
        // Run this same test in a fresh XCTest process, using the production flock implementation.
        if let path = environment["TEAMS_TEST_CHILD_LOCK_PATH"] {
            if environment["TEAMS_TEST_CHILD_LOCK_EXPECTATION"] == "busy" {
                assertCommandError(.commandInProgress) { try MediaCommandLock(path: path) }
            } else {
                XCTAssertNoThrow(try MediaCommandLock(path: path).release())
            }
            print("lock-child-completed")
            return
        }

        let directory = try temporaryCommandDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command.lock").path
        let held = try MediaCommandLock(path: path)
        defer { held.release() }
        try runChild(path: path, expectation: "busy", directory: directory)
        held.release()
        try runChild(path: path, expectation: "available", directory: directory)
    }

    private func runChild(path: String, expectation: String, directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "\(NSStringFromClass(Self.self))/testLockContendsAcrossProcesses",
                             Bundle(for: Self.self).bundleURL.path]
        var environment = [
            "PATH": "/usr/bin:/bin", "TEAMS_TEST_CHILD_LOCK_PATH": path,
            "TEAMS_TEST_CHILD_LOCK_EXPECTATION": expectation,
            // Keep child profiles separate from the coverage run of the parent suite.
            "LLVM_PROFILE_FILE": directory.appendingPathComponent("child-%p.profraw").path
        ]
        for key in ["HOME", "TMPDIR", "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"] {
            environment[key] = ProcessInfo.processInfo.environment[key]
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let exited = self.expectation(description: "Child lock check finishes without waiting for the lock")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 10)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("lock-child-completed"), "The child must actually run the selected test")
    }
}
