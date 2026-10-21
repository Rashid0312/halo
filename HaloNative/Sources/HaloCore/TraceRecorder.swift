import CryptoKit
import Foundation

/// Opt-in, local-only recording of tool-using turns, as training examples for
/// Halo's own model. Off unless the user turns it on in Settings → Privacy.
/// Text is scrubbed of common private data before it is written; screenshots
/// are never saved. Files live in ~/Library/Application Support/Halo/Traces:
/// one JSON line per turn in `<date>.jsonl`, with tool lists and instructions
/// stored once each under `blobs/` and referenced by hash.
public final class TraceRecorder: @unchecked Sendable {
    public static let shared = TraceRecorder()
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Halo/Traces")
    /// Longest tool result kept per call; results are already bounded by the tools.
    static let maxOutput = 16_000

    private let lock = NSLock()
    private var enabled = false
    private var folder: URL
    public init(directory: URL = TraceRecorder.defaultDirectory) { folder = directory }

    /// Where traces are written; tests point it at a separate folder.
    public var directory: URL {
        get { lock.withLock { folder } }
        set { lock.withLock { folder = newValue } }
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Starts a trace for one request, or nil when recording is off.
    public func begin(brain: String, instructions: String, messages: [Message], tools: Data?) -> TraceDraft? {
        guard isEnabled, let prompt = messages.last(where: \.isUser)?.text else { return nil }
        let history = messages.dropLast().suffix(19).map { TraceDraft.Turn(role: $0.isUser ? "user" : "assistant", text: Scrubber.scrub($0.text)) }
        return TraceDraft(recorder: self, brain: brain, instructionsHash: store(Data(instructions.utf8), ext: "txt"),
                          toolsHash: tools.map { store($0, ext: "json") }, history: Array(history), prompt: Scrubber.scrub(prompt))
    }

    /// Number of turns recorded so far.
    public func count() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.reduce(0) { total, file in
            total + ((try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").count ?? 0)
        }
    }

    private func store(_ data: Data, ext: String) -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        let url = directory.appendingPathComponent("blobs/\(hash).\(ext)")
        lock.withLock {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
        return String(hash)
    }

    fileprivate func write(_ trace: TraceDraft.Record) {
        guard isEnabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(trace) else { return }
        line.append(0x0A)
        let day = String(ISO8601DateFormatter().string(from: trace.date).prefix(10))
        let url = directory.appendingPathComponent("\(day).jsonl")
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
    }
}

/// One request being recorded. Filled in by AgentLoop and written on finish.
public final class TraceDraft: @unchecked Sendable {
    struct Turn: Codable { var role: String; var text: String }
    struct Call: Codable {
        var name: String
        var arguments: String
        var output: String
        /// Rejected by ToolValidator, not run.
        var rejected: Bool
    }
    struct Step: Codable { var text: String; var calls: [Call] }
    struct Outcome: Codable {
        /// "answered", "error", or "cancelled".
        var end: String
        var error: String?
        var toolErrors: Int
        var rejectedCalls: Int
        var deniedApprovals: Int
    }
    struct Record: Codable {
        var id: UUID
        var date: Date
        var brain: String
        var instructions: String
        var tools: String?
        var history: [Turn]
        var prompt: String
        var steps: [Step]
        var answer: String
        var outcome: Outcome
    }

    private let lock = NSLock()
    private weak var recorder: TraceRecorder?
    private var record: Record
    private var answer = ""
    private var finished = false

    fileprivate init(recorder: TraceRecorder, brain: String, instructionsHash: String, toolsHash: String?, history: [Turn], prompt: String) {
        self.recorder = recorder
        record = Record(id: UUID(), date: Date(), brain: brain, instructions: instructionsHash, tools: toolsHash, history: history,
                        prompt: prompt, steps: [], answer: "",
                        outcome: Outcome(end: "answered", toolErrors: 0, rejectedCalls: 0, deniedApprovals: 0))
    }

    /// Visible text streamed in the current round.
    public func appendText(_ text: String) { lock.withLock { answer += text } }

    /// A round that ended in tool calls; its streamed text belongs to the step.
    public func addStep(text: String, outputs: [ToolOutput], rejected: Set<String>) {
        let calls = outputs.map { output -> Call in
            var text = output.text
            if !output.imageURLs.isEmpty { text = Self.withoutImage(text) }
            return Call(name: output.call.name, arguments: Scrubber.scrub(output.call.arguments),
                        output: Scrubber.scrub(String(text.prefix(TraceRecorder.maxOutput))), rejected: rejected.contains(output.call.id))
        }
        lock.withLock {
            answer = ""
            record.steps.append(Step(text: Scrubber.scrub(text), calls: calls))
            for (call, output) in zip(calls, outputs) {
                if call.rejected { record.outcome.rejectedCalls += 1; continue }
                let object = (try? JSONSerialization.jsonObject(with: Data(output.text.utf8))) as? [String: Any]
                if object?["ok"] as? Bool == false {
                    if object?["denied"] as? Bool == true { record.outcome.deniedApprovals += 1 } else { record.outcome.toolErrors += 1 }
                }
            }
        }
    }

    public func finish(error: (any Error)? = nil) {
        let snapshot: Record? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            record.answer = Scrubber.scrub(answer)
            if let error {
                record.outcome.end = error is CancellationError ? "cancelled" : "error"
                record.outcome.error = error is CancellationError ? nil : error.localizedDescription
            }
            return record
        }
        if let snapshot { recorder?.write(snapshot) }
    }

    private static func withoutImage(_ text: String) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return text }
        object["image"] = "screenshot shown to the model; not saved"
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data(text.utf8), as: UTF8.self)
    }
}

/// Replaces common private data with placeholders before a trace is written.
/// Catches structured data (emails, phone and card numbers, keys, home paths);
/// it cannot recognise names or free-form personal text, which is why traces
/// stay local and a shared model must be trained on reviewed data only.
public enum Scrubber {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
        (#"(?i)\b(sk|pk|rk|ghp|gho|ghs|xox[abp])[-_][A-Za-z0-9_-]{16,}"#, "<secret>"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"#, "Bearer <secret>"),
        (#"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#, "<secret>"),
        (#"\b[A-Fa-f0-9]{40,}\b"#, "<secret>"),
        // Phone numbers need a leading + or separators, so plain IDs survive.
        (#"\+\d{1,3}(?:[ .-]?\(?\d{2,4}\)?){2,5}\b"#, "<phone>"),
        (#"\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b"#, "<phone>"),
        (#"/Users/[^/\s"']+"#, "/Users/user"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private static let digitRun = try! NSRegularExpression(pattern: #"\b\d(?:[ -]?\d){12,18}\b"#)

    /// Scrubs plain text, or only the string values when `text` is JSON, so
    /// numbers such as tab IDs and the JSON structure itself stay intact.
    public static func scrub(_ text: String) -> String {
        if let first = text.first, first == "{" || first == "[",
           let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           let data = try? JSONSerialization.data(withJSONObject: scrubValue(value), options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return scrubText(text)
    }

    private static func scrubValue(_ value: Any) -> Any {
        switch value {
        case let text as String: scrubText(text)
        case let array as [Any]: array.map(scrubValue)
        case let object as [String: Any]: object.mapValues(scrubValue)
        default: value
        }
    }

    private static func scrubText(_ text: String) -> String {
        var text = rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
        // Card numbers: 13-19 digits that pass the Luhn check.
        for match in digitRun.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), luhn(text[range].filter(\.isNumber)) else { continue }
            text.replaceSubrange(range, with: "<number>")
        }
        return text
    }

    private static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            var digit = character.wholeNumberValue ?? 0
            if index % 2 == 1 { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
        }
        return sum % 10 == 0
    }
}
