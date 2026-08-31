import Foundation

struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: LocalizedError {
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .executionFailed(let cmd, let code, let stderr):
            "Command '\(cmd)' failed (exit \(code)): \(stderr)"
        case .cancelled:
            "Operation cancelled"
        }
    }
}

/// Runs a subprocess off the main thread and honors structured-concurrency
/// cancellation by terminating the underlying `Process`.
enum ShellRunner {
    static func run(_ executable: String, arguments: [String]) async throws -> ShellResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    Self.currentProcessLock.lock()
                    Self.currentProcesses.insert(process)
                    Self.currentProcessLock.unlock()

                    defer {
                        Self.currentProcessLock.lock()
                        Self.currentProcesses.remove(process)
                        Self.currentProcessLock.unlock()
                    }

                    do {
                        try process.run()
                        process.waitUntilExit()

                        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                        if process.terminationReason == .uncaughtSignal
                            && process.terminationStatus == SIGTERM {
                            continuation.resume(throwing: ShellError.cancelled)
                            return
                        }

                        let result = ShellResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Terminate every process started by this runner. Ongoing Tasks
            // will see their process exit with SIGTERM and propagate the
            // `.cancelled` error up to the caller.
            Self.currentProcessLock.lock()
            let active = Self.currentProcesses
            Self.currentProcessLock.unlock()
            for process in active where process.isRunning {
                process.terminate()
            }
        }
    }

    // MARK: - Process tracking

    private static let currentProcessLock = NSLock()
    nonisolated(unsafe) private static var currentProcesses: Set<Process> = []
}
