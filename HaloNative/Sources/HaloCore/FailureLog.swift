import Foundation

/// Every failure Halo hits, kept on this Mac so problems are caught instead of
/// lost: a turn that failed, a tool call Halo refused to run, and a tool that
/// returned an error. Always on, unlike the opt-in training recorder. One JSON
/// line each in ~/Library/Logs/Halo/failures.jsonl. Details are scrubbed and
/// capped; tool arguments, prompts, and replies are never written. When the
/// file passes 2 MB the older half is dropped.
public final class FailureLog: @unchecked Sendable {
    public enum Kind: String, Sendable {
        case turnFailed = "turn_failed"
        case callRejected = "call_rejected"
        case toolError = "tool_error"
    }

    /// HALO_FAILURE_LOG redirects it (checks use a temporary file).
    public static let shared = FailureLog(url: ProcessInfo.processInfo.environment["HALO_FAILURE_LOG"].map { URL(fileURLWithPath: $0) } ?? defaultURL)
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Halo/failures.jsonl")
    public let url: URL
    private let lock = NSLock()
    private static let limit = 2 * 1024 * 1024

    public init(url: URL = FailureLog.defaultURL) { self.url = url }

    public func record(_ kind: Kind, tool: String? = nil, detail: String) {
        var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "kind": kind.rawValue,
                                  "detail": String(Scrubber.scrub(detail).prefix(500)),
                                  "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"]
        if let tool { row["tool"] = tool }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit,
               let old = try? Data(contentsOf: url) {
                let kept = old.suffix(Self.limit / 2)
                let start = kept.firstIndex(of: 0x0A).map { kept.index(after: $0) } ?? kept.startIndex
                try? Data(kept[start...]).write(to: url, options: .atomic)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (data + Data("\n".utf8)).write(to: url)
            }
        }
    }

    /// The newest entries first, for Settings and checks.
    public func recent(_ count: Int = 20) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(count).reversed()
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}
