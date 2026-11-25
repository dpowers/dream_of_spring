//
//  BoundedCommand.swift
//  Dream Of Spring
//
import Foundation

/// Runs a fixed executable with a hard time limit, for the root helper.
/// Shared with the app target only so the behaviour is unit-testable.
nonisolated enum BoundedCommand {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case launch(String)
        case timedOut
        case exit(Int32)
        case unreadableOutput

        var description: String {
            switch self {
            case .launch(let reason): "could not launch: \(reason)"
            case .timedOut: "timed out"
            case .exit(let status): "exited with status \(status)"
            case .unreadableOutput: "produced unreadable output"
            }
        }
    }

    /// Returns standard output on a zero exit. Commands that print nothing
    /// (such as `pmset -a disablesleep 0`) succeed with an empty string:
    /// `FileHandle.readToEnd()` reports empty output as nil, not as empty data.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(.launch(error.localizedDescription)) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return .failure(.timedOut)
        }
        guard process.terminationStatus == 0 else { return .failure(.exit(process.terminationStatus)) }
        let data: Data
        do { data = try pipe.fileHandleForReading.readToEnd() ?? Data() } catch { return .failure(.unreadableOutput) }
        guard let output = String(data: data, encoding: .utf8) else { return .failure(.unreadableOutput) }
        return .success(output)
    }
}
