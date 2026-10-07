import Foundation

let runner = CommandRunner(handlers: .live, writeStdout: {
    FileHandle.standardOutput.write(Data($0.utf8))
}, writeStderr: {
    FileHandle.standardError.write(Data($0.utf8))
})
exit(runner.run(Array(CommandLine.arguments.dropFirst())))
