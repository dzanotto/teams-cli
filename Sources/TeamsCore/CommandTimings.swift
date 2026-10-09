import Foundation

/// Buffered diagnostics for one synchronous invocation. Never shared across commands or threads.
/// All measurements use a separate clock; action deadlines keep their original clock and reads.
public final class CommandTimings {
    struct Span: Encodable {
        let id: Int
        let parentID: Int?
        let name: String
        let startMS: Double
        var durationMS: Double = 0
        var threw = false
        var counters: [String: Int] = [:]
        var details: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case id, name, threw, counters, details
            case parentID = "parent_id", startMS = "start_ms", durationMS = "duration_ms"
        }
    }

    private struct Outcome: Encodable {
        let state: String
        let reason: String?
        let success: Bool?
        let actionAttempted: Bool?
        let changed: Bool?

        enum CodingKeys: String, CodingKey {
            case state, reason, success, changed
            case actionAttempted = "action_attempted"
        }
    }

    private struct Record: Encodable {
        let type = "timings"
        let schemaVersion = 1
        let command: String
        let exitCode: Int32
        let elapsedMS: Double
        let outcome: Outcome?
        let spans: [Span]

        enum CodingKeys: String, CodingKey {
            case type, command, outcome, spans
            case schemaVersion = "schema_version", exitCode = "exit_code", elapsedMS = "elapsed_ms"
        }
    }

    private let clock: () -> TimeInterval
    private let startedAt: TimeInterval
    private var stack = [0]
    private(set) var spans: [Span] = [Span(id: 0, parentID: nil, name: "command", startMS: 0)]
    private var outcome: Outcome?

    public init(startedAt: TimeInterval? = nil,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.startedAt = startedAt ?? clock()
    }

    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let id = spans.count
        let start = clock()
        spans.append(Span(id: id, parentID: stack.last, name: name, startMS: (start - startedAt) * 1_000))
        stack.append(id)
        var threw = true
        defer {
            spans[id].durationMS = (clock() - start) * 1_000
            spans[id].threw = threw
            stack.removeLast()
        }
        let value = try body()
        threw = false
        return value
    }

    func increment(_ name: String, by amount: Int = 1) {
        guard let id = stack.last else { return }
        spans[id].counters[name, default: 0] += amount
    }

    func detail(_ name: String, _ value: String) {
        guard let id = stack.last else { return }
        spans[id].details[name] = value
    }

    public func recordOutcome(state: String, reason: String?, success: Bool?, attempted: Bool?, changed: Bool?) {
        outcome = Outcome(state: state, reason: reason, success: success, actionAttempted: attempted, changed: changed)
    }

    /// Closes the root before encoding or writing. The caller handles diagnostic I/O failure separately.
    public func emit(command: String, exitCode: Int32, write: (String) throws -> Void) throws {
        spans[0].durationMS = (clock() - startedAt) * 1_000
        let record = Record(command: command, exitCode: exitCode, elapsedMS: spans[0].durationMS,
                            outcome: outcome, spans: spans)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try write(String(decoding: data, as: UTF8.self) + "\n")
    }
}

extension Optional where Wrapped == CommandTimings {
    /// The disabled path executes only the original operation, without reading a timing clock.
    public func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard let recorder = self else { return try body() }
        return try recorder.measure(name, body)
    }
}
