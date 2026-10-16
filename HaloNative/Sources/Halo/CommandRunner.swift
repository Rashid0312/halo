import Foundation
import Darwin

/// Runs off the UI actor. Only approved source reaches this executor.
enum CommandRunner {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let truncated: Bool
        let timedOut: Bool
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func cancel() { lock.lock(); stopped = true; lock.unlock() }
        func launch(_ process: Process) throws {
            lock.lock(); defer { lock.unlock() }
            if stopped { throw CancellationError() }
            try process.run()
        }
        var requested: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    static func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval = 60) async throws -> Result {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            let job = Task.detached(priority: .utility) {
                if cancellation.requested { throw CancellationError() }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = directory
                // Do not automatically expose Halo's provider credentials to commands.
                process.environment = ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
                process.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                process.standardOutput = out; process.standardError = err
                defer {
                    try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
                    try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                }
                for handle in [out.fileHandleForReading, err.fileHandleForReading] {
                    let flags = fcntl(handle.fileDescriptor, F_GETFL)
                    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                        throw CocoaError(.fileReadUnknown)
                    }
                }
                if cancellation.requested { throw CancellationError() }
                try cancellation.launch(process)
                try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                var stdout = Data(), stderr = Data(), truncated = false
                let deadline = Date().addingTimeInterval(timeout)
                var stoppingAt: Date?, timedOut = false
                func drain(_ handle: FileHandle, into output: inout Data) {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    // Bound each pass so continuous output cannot starve cancellation.
                    for _ in 0..<32 {
                        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                        guard count > 0 else { break }
                        let remaining = max(0, 32768 - output.count)
                        output.append(contentsOf: buffer.prefix(min(count, remaining)))
                        if count > remaining { truncated = true }
                    }
                }
                while true {
                    drain(out.fileHandleForReading, into: &stdout)
                    drain(err.fileHandleForReading, into: &stderr)
                    if !process.isRunning { break }
                    if stoppingAt == nil, cancellation.requested || Date() >= deadline {
                        timedOut = !cancellation.requested
                        stoppingAt = Date()
                        process.terminate()
                    }
                    if let stoppingAt, Date().timeIntervalSince(stoppingAt) >= 0.5, process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    usleep(10_000)
                }
                process.waitUntilExit()
                drain(out.fileHandleForReading, into: &stdout)
                drain(err.fileHandleForReading, into: &stderr)
                if cancellation.requested { throw CancellationError() }
                return Result(status: process.terminationStatus,
                              stdout: String(decoding: stdout, as: UTF8.self),
                              stderr: String(decoding: stderr, as: UTF8.self),
                              truncated: truncated, timedOut: timedOut)
            }
            return try await job.value
        } onCancel: { cancellation.cancel() }
    }
}
