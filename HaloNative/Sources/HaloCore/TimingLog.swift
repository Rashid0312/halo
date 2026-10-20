import Foundation

/// Local, privacy-safe timing of a conversation turn: phase names, tool names,
/// and milliseconds since the user sent the prompt. Never prompts, replies,
/// page content, or credentials. Written to ~/Library/Logs/Halo/timing.log.
public final class TimingLog: @unchecked Sendable {
    public static let shared = TimingLog()
    private let lock = NSLock()
    private var turnStart: ContinuousClock.Instant?
    private var turn = 0
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Halo/timing.log")

    public func beginTurn(_ label: String) {
        let number: Int = lock.withLock { turn += 1; turnStart = .now; return turn }
        write("=== turn \(number) \(label) @ \(ISO8601DateFormatter().string(from: Date()))")
    }

    public func mark(_ phase: String) {
        let elapsed: String = lock.withLock {
            guard let start = turnStart else { return "?" }
            let d = start.duration(to: .now)
            return String(format: "%7.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        write("\(elapsed)  \(phase)")
    }

    /// Test-only: logs whenever the main thread takes longer than `threshold`
    /// to service a ping, i.e. work queued for it (tool calls, UI) is waiting.
    public func startMainThreadMonitor(threshold: TimeInterval = 0.5) {
        let thread = Thread { [weak self] in
            while true {
                let sent = Date()
                let responded = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { responded.signal() }
                responded.wait()
                let delay = Date().timeIntervalSince(sent)
                if delay > threshold { self?.mark(String(format: "MAIN THREAD BLOCKED %.0f ms", delay * 1000)) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "Halo main-thread monitor"
        thread.start()
    }

    private func write(_ line: String) {
        lock.withLock {
            let data = Data((line + "\n").utf8)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
