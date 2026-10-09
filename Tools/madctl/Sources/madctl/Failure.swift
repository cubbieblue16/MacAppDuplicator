import ArgumentParser
import Foundation

/// Prints `error: <description>` to stderr and returns the exit-1 error to throw.
func runtimeFailure(_ error: Error) -> ExitCode {
    printError("error: \(error.localizedDescription)")
    return ExitCode(1)
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
