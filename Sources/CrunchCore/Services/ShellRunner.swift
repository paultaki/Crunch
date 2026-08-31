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
///
/// Cancellation is scoped to a single `run(_:arguments:)` invocation: each
/// call owns a private `ProcessBox` and can only ever terminate its own
/// child. A shared registry would mean cancelling one estimate kills the
/// pngquant/cwebp processes of an unrelated compression run.
enum ShellRunner {
    static func run(_ executable: String, arguments: [String]) async throws -> ShellResult {
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    do {
                        // The box launches under its own lock so a cancel
                        // racing this line either happens first (nothing
                        // starts) or after (the child is registered and
                        // killable) — never in between, which would leave an
                        // orphan no one holds a handle to.
                        guard try box.start(process) else {
                            continuation.resume(throwing: ShellError.cancelled)
                            return
                        }

                        // Drain both pipes to EOF BEFORE waiting on exit. A
                        // child that writes more than the 64KB pipe buffer
                        // blocks forever otherwise, and this process would
                        // block forever waiting for it.
                        let stderrBuffer = DataBox()
                        let stderrDrained = DispatchGroup()
                        stderrDrained.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            stderrBuffer.value = stderrPipe.fileHandleForReading
                                .readDataToEndOfFile()
                            stderrDrained.leave()
                        }

                        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        stderrDrained.wait()
                        process.waitUntilExit()

                        if process.terminationReason == .uncaughtSignal
                            && process.terminationStatus == SIGTERM {
                            continuation.resume(throwing: ShellError.cancelled)
                            return
                        }

                        let result = ShellResult(
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrBuffer.value, encoding: .utf8) ?? ""
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Per-invocation process ownership

    /// Holds the one `Process` a single `run` call spawned, plus whether that
    /// call was cancelled. `@unchecked Sendable` because the lock, not the
    /// compiler, provides the exclusion.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        /// Launches `process` and takes ownership of it, or returns `false`
        /// when this invocation was already cancelled (caller should resume
        /// with `ShellError.cancelled` and start nothing).
        func start(_ process: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else { return false }
            try process.run()
            self.process = process
            return true
        }

        /// Marks this invocation cancelled and SIGTERMs its child if one is
        /// already running. `terminate()` runs outside the lock; it never
        /// calls back into the box, and holding the lock across it would
        /// serialize against an in-flight `start`.
        func cancel() {
            lock.lock()
            isCancelled = true
            let running = process
            lock.unlock()

            if let running, running.isRunning {
                running.terminate()
            }
        }
    }

    /// Minimal thread-safe box so the stderr drain, which runs on its own
    /// queue, can hand its bytes back to the waiting caller without tripping
    /// Swift 6 sendability on a captured `var`.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        var value: Data {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }
}
