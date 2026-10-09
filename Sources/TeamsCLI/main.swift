import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let timingStart = arguments.contains("--timings") ? ProcessInfo.processInfo.systemUptime : nil
let runner = CommandRunner(handlers: .live, writeStdout: {
    FileHandle.standardOutput.write(Data($0.utf8))
}, writeStderr: {
    FileHandle.standardError.write(Data($0.utf8))
}, writeTimings: {
    // Normal output and the action have finished. A closed diagnostic pipe must not
    // terminate an otherwise completed invocation with SIGPIPE.
    let previous = signal(SIGPIPE, SIG_IGN)
    defer { signal(SIGPIPE, previous) }
    try FileHandle.standardError.write(contentsOf: Data($0.utf8))
})
exit(runner.run(arguments, startedAt: timingStart))
