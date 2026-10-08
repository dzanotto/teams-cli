import XCTest
@testable import TeamsCLI
@testable import TeamsCore

final class CLIArgumentTests: XCTestCase {
    func testVersionPrintsDevelopmentVersionWithoutInvokingHandlers() {
        let stub = CLIStub()
        stub.error = CLIStubError.unexpected
        let result = stub.run(["--version"])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.stdout, "teams-cli dev\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(stub.calls, [])
    }

    func testVersionRejectsOtherArgumentsAndAliases() {
        for arguments in [["--version", "--json"], ["--json", "--version"],
                          ["--version", "--help"], ["--help", "--version"],
                          ["--version", "-h"], ["--version", "--version"],
                          ["--version", "--window", "1"], ["--version=1"], ["-v"], ["-V"]] {
            assertInvalid(arguments)
        }
        let commands = ["mic", "camera", "hand", "call"].map { [$0] } +
            ["mic", "camera", "hand"].map { [$0, "status"] } + cliActionRoutes.map(\.arguments)
        for command in commands {
            assertInvalid(command + ["--version"])
            assertInvalid(["--version"] + command)
        }
    }

    func testHelpAtRootGroupAndEveryValidCommandDoesNotInvokeHandlers() {
        let commands = [[String]()] + ["mic", "camera", "hand", "call"].map { [$0] } +
            ["mic", "camera", "hand"].map { [$0, "status"] } + cliActionRoutes.map(\.arguments)
        let expectedHelp = CLIStub().run(["--help"]).stdout
        for command in commands {
            for flag in ["--help", "-h"] {
                let stub = CLIStub()
                stub.error = CLIStubError.unexpected
                let result = stub.run(command + [flag])
                XCTAssertEqual(result.code, 0, "\(command) \(flag)")
                XCTAssertEqual(result.stdout, expectedHelp)
                XCTAssertEqual(result.stderr, "")
                XCTAssertEqual(stub.calls, [])
            }
        }
    }

    func testHelpDocumentsCommandsFlagsAndExitCodes() {
        let help = CLIStub().run(["--help"]).stdout
        for line in ["teams-cli mic status [--json] [--window N]",
                     "teams-cli mic <mute|unmute|toggle> [--json]",
                     "teams-cli camera status [--json] [--window N]",
                     "teams-cli camera <on|off|toggle> [--json]",
                     "teams-cli hand status [--json] [--window N]",
                     "teams-cli hand <raise|lower|toggle> [--json]",
                     "teams-cli call end [--json]",
                     "teams-cli --version", "--version    Show the build version;",
                     "--window N   Status only:", "-h, --help",
                     "0 help, version, known state, or verified action;",
                     "2 unknown/ambiguous; 3 accessibility denied;",
                     "4 Teams not running; 5 read failure; 6 action refused/unverified;",
                     "64 invalid arguments."] {
            XCTAssertTrue(help.contains(line), line)
        }
        XCTAssertTrue(help.hasPrefix("Usage: "))
        XCTAssertTrue(help.hasSuffix("\n"))
    }

    func testAllUnsupportedMediaOperationPairsAreRejectedBeforeDispatch() {
        let valid = Set((cliActionRoutes.map(\.arguments) + ["mic", "camera", "hand"].map { [$0, "status"] })
            .map { $0.joined(separator: " ") })
        for media in ["mic", "camera", "hand", "call"] {
            for operation in ["status", "mute", "unmute", "toggle", "on", "off", "end", "raise", "lower"] {
                let arguments = [media, operation]
                if !valid.contains(arguments.joined(separator: " ")) { assertInvalid(arguments) }
            }
        }
    }

    func testMissingUnknownAndCaseMismatchedArgumentsAreRejected() {
        for arguments in [[], ["mic"], ["camera"], ["hand"], ["call"], ["status"],
                          ["microphone", "status"], ["MIC", "status"], ["mic", "STATUS"],
                          ["mic", "bogus"], ["mic", "status", "extra"], ["--json", "mic", "status"]] {
            assertInvalid(arguments)
        }
    }

    func testHelpDoesNotRescueInvalidCommandsOrExtraOptions() {
        for arguments in [["bogus", "--help"], ["mic", "on", "--help"], ["call", "status", "-h"],
                          ["--help", "mic"], ["mic", "--help", "status"], ["--help", "--help"],
                          ["mic", "status", "--json", "--help"], ["mic", "status", "--help", "--json"]] {
            assertInvalid(arguments)
        }
    }

    func testUnknownAndDuplicateFlagsAreRejected() {
        for suffix in [["--json", "--json"], ["--window", "1", "--window", "2"],
                       ["--window", "1", "--json", "--window", "1"], ["--verbose"],
                       ["--json=true"], ["--window=1"], ["-j"], ["--"]] {
            assertInvalid(["mic", "status"] + suffix)
        }
    }

    func testWindowRequiresOnePositiveRepresentableInteger() {
        for suffix in [["--window"], ["--window", "--json"], ["--window", "0"],
                       ["--window", "-1"], ["--window", "1.5"], ["--window", "one"],
                       ["--window", ""], ["--window", String(Int.max) + "0"]] {
            assertInvalid(["mic", "status"] + suffix)
        }
    }

    func testEveryActionRejectsWindowSelection() {
        for route in cliActionRoutes {
            assertInvalid(route.arguments + ["--window", "1"])
            assertInvalid(route.arguments + ["--json", "--window", "1"])
        }
    }

    func testStatusAcceptsEitherFlagOrderAndDispatchesCorrectControl() throws {
        for (media, control, key, state) in [("mic", "microphone-button", "microphone", "unmuted"),
                                           ("camera", "video-button", "camera", "on"),
                                           ("hand", "raisehands-button", "hand", "lowered")] {
            for flags in [["--json", "--window", "1"], ["--window", "1", "--json"]] {
                let stub = CLIStub()
                let result = stub.run([media, "status"] + flags)
                XCTAssertEqual(result.code, 0)
                XCTAssertEqual(stub.calls, ["read:\(control)"])
                XCTAssertEqual(try cliJSON(result)[key] as? String, state)
            }
        }
    }

    private func assertInvalid(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let stub = CLIStub()
        let result = stub.run(arguments)
        XCTAssertEqual(result.code, 64, "\(arguments)", file: file, line: line)
        XCTAssertEqual(result.stdout, "", file: file, line: line)
        XCTAssertEqual(result.stderr, CLIStub().run(["--help"]).stdout, file: file, line: line)
        XCTAssertEqual(stub.calls, [], file: file, line: line)
    }
}
