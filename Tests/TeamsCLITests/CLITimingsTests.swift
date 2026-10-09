import XCTest
@testable import TeamsCLI
@testable import TeamsCore

final class CLITimingsTests: XCTestCase {
    func testToggleTimingsPreserveNormalOutputAndReachHandler() throws {
        for media in ["mic", "camera"] {
            for flags in [[String](), ["--json"]] {
                let baseline = CLIStub().run([media, "toggle"] + flags)
                for timingFlags in [["--timings"] + flags, flags + ["--timings"]] {
                    let stub = CLIStub()
                    stub.onToggle = { XCTAssertNotNil($0) }
                    let actual = stub.run([media, "toggle"] + timingFlags)
                    XCTAssertEqual(actual.code, baseline.code)
                    XCTAssertEqual(actual.stdout, baseline.stdout)
                    XCTAssertEqual(stub.calls, ["\(media):toggle"])
                    let record = try trace(actual)
                    XCTAssertEqual(record["command"] as? String, "\(media) toggle")
                    XCTAssertEqual(record["exit_code"] as? Int, 0)
                    let outcome = try XCTUnwrap(record["outcome"] as? [String: Any])
                    XCTAssertEqual(outcome["success"] as? Bool, true)
                    XCTAssertEqual(outcome["action_attempted"] as? Bool, true)
                    XCTAssertEqual(outcome["changed"] as? Bool, true)
                    let spans = try XCTUnwrap(record["spans"] as? [[String: Any]])
                    XCTAssertEqual(spans.map { $0["name"] as? String }, ["command", "result_output"])
                }
            }
        }
    }

    func testDisabledTimingsNeverReadClockOrProvideRecorder() {
        let stub = CLIStub()
        stub.timingClock = { XCTFail("Disabled instrumentation read its clock"); return 0 }
        stub.onToggle = { XCTAssertNil($0) }
        stub.writeTimings = { _ in XCTFail("Disabled instrumentation emitted a trace") }
        for media in ["mic", "camera"] {
            XCTAssertEqual(stub.run([media, "toggle"]).stderr, "")
        }
    }

    func testInvalidTimingOptionsDoNotInvokeHandlersOrEmitTraces() {
        let invalid = [["mic", "toggle", "--timings", "--timings"],
                       ["camera", "toggle", "--timings", "--window", "1"], ["--timings"],
                       ["--version", "--timings"], ["mic", "toggle", "--timings=true"]]
        let unsupported = cliActionRoutes.map(\.arguments).filter { $0 != ["mic", "toggle"] && $0 != ["camera", "toggle"] }
            + ["mic", "camera", "hand"].map { [$0, "status"] }
        for arguments in invalid + unsupported.map({ $0 + ["--timings"] }) {
            let stub = CLIStub()
            let result = stub.run(arguments)
            XCTAssertEqual(result.code, 64, "\(arguments)")
            XCTAssertEqual(result.stdout, "")
            XCTAssertTrue(result.stderr.hasPrefix("Usage: "))
            XCTAssertFalse(result.stderr.contains("\"type\":\"timings\""))
            XCTAssertEqual(stub.calls, [])
        }
    }

    func testHandledFailuresKeepExistingErrorsBeforeFinalTrace() throws {
        for media in ["mic", "camera"] {
            for json in [false, true] {
                for throwsError in [false, true] {
                    let stub = CLIStub()
                    if throwsError {
                        stub.error = TeamsReadError.accessibilityDenied
                    } else {
                        stub.useActionResults(success: false, changed: nil, attempted: true, focus: true,
                                              reason: "verification_timeout", unknown: true)
                    }
                    let args = [media, "toggle"] + (json ? ["--json"] : [])
                    let baseline = stub.run(args)
                    let actual = stub.run(args + ["--timings"])
                    XCTAssertEqual(actual.stdout, baseline.stdout)
                    XCTAssertEqual(actual.code, baseline.code)
                    XCTAssertTrue(actual.stderr.hasPrefix(baseline.stderr))
                    let record = try trace(actual)
                    XCTAssertEqual(record["exit_code"] as? Int32, baseline.code)
                    let outcome = try XCTUnwrap(record["outcome"] as? [String: Any])
                    XCTAssertEqual(outcome["reason"] as? String,
                                   throwsError ? "accessibility_permission_required" : "verification_timeout")
                }
            }
        }
    }

    func testTraceIncludesOutputTimeAndExcludesDiagnosticWriteTime() throws {
        var now: TimeInterval = 10
        let stub = CLIStub()
        stub.timingClock = { now }
        stub.onToggle = { timings in timings?.measure("fake_action") { now += 2 } }
        stub.onStdout = { now += 3 }
        var traceText = ""
        stub.writeTimings = { traceText = $0; now += 20 }
        let result = stub.run(["mic", "toggle", "--timings"])
        XCTAssertEqual(result.code, 0)
        let record = try trace(CLIResult(code: result.code, stdout: result.stdout, stderr: traceText))
        XCTAssertEqual(record["elapsed_ms"] as? Double, 5_000)
        XCTAssertEqual(now, 35)
        let spans = try XCTUnwrap(record["spans"] as? [[String: Any]])
        XCTAssertEqual(spans.last?["duration_ms"] as? Double, 3_000)
    }

    func testDiagnosticWriteFailureDoesNotChangeSuccessOrFailure() {
        for success in [true, false] {
            let stub = CLIStub()
            stub.useActionResults(success: success, changed: success ? true : nil, attempted: true, focus: true,
                                  reason: success ? nil : "verification_timeout", unknown: !success)
            stub.writeTimings = { _ in throw CLIStubError.unexpected }
            let baseline = stub.run(["camera", "toggle"])
            let actual = stub.run(["camera", "toggle", "--timings"])
            XCTAssertEqual(actual.code, baseline.code)
            XCTAssertEqual(actual.stdout, baseline.stdout)
            XCTAssertEqual(actual.stderr, baseline.stderr)
            XCTAssertEqual(stub.calls, ["camera:toggle", "camera:toggle"])
        }
    }

    private func trace(_ result: CLIResult) throws -> [String: Any] {
        let line = try XCTUnwrap(result.stderr.split(separator: "\n").last)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(record["type"] as? String, "timings")
        XCTAssertEqual(record["schema_version"] as? Int, 1)
        return record
    }
}
