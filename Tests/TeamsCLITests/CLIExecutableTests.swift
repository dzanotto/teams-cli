import Darwin
import Foundation
import XCTest

final class CLIExecutableTests: XCTestCase {
    func testExecutableVersionPrintsDevelopmentVersion() throws {
        let actual = try launch(["--version"])
        XCTAssertEqual(actual.code, 0)
        XCTAssertEqual(actual.stdout, "teams-cli dev\n")
        XCTAssertEqual(actual.stderr, "")
    }

    func testExecutableHelpMatchesRunnerAtRootGroupAndCommand() throws {
        for arguments in [["--help"], ["camera", "-h"], ["call", "end", "--help"]] {
            let actual = try launch(arguments)
            let expected = CLIStub().run(arguments)
            XCTAssertEqual(actual.code, 0)
            XCTAssertEqual(actual.stdout, expected.stdout)
            XCTAssertEqual(actual.stderr, "")
        }
    }

    func testExecutableInvalidArgumentsReturn64WithUsageOnlyOnStderr() throws {
        for arguments in [[], ["call", "status"], ["mic", "status", "--json", "--json"],
                          ["hand", "toggle", "--window", "1"], ["--version", "--json"],
                          ["mic", "toggle", "--version"], ["--version", "--help"]] {
            let actual = try launch(arguments)
            let expected = CLIStub().run(arguments)
            XCTAssertEqual(actual.code, 64)
            XCTAssertEqual(actual.stdout, "")
            XCTAssertEqual(actual.stderr, expected.stderr)
        }
    }

    /// Only help, version, and invalid arguments may be passed here: native actions require live authorization.
    private func launch(_ arguments: [String]) throws -> CLIResult {
        let binaryDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = binaryDirectory.appendingPathComponent("teams-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin"]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"] {
            environment[key] = inherited[key]
        }
        // Place child coverage alongside the test profile so SwiftPM merges entry-point coverage.
        let profileDirectory = inherited["LLVM_PROFILE_FILE"].map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        } ?? directory
        environment["LLVM_PROFILE_FILE"] = profileDirectory.appendingPathComponent("cli-smoke-%p-%m.profraw").path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = expectation(description: "CLI exits without accessing Teams")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        wait(for: [finished], timeout: 10)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        return CLIResult(code: process.terminationStatus,
                         stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                         stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
