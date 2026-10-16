import Foundation

public enum ProviderError: LocalizedError {
    case missingKey, http(Int), invalidStream, interruptedStream, toolLimit
    public var errorDescription: String? {
        switch self {
        case .toolLimit: "The request reached the action limit. Please ask for the next step."
        case .missingKey: "The existing DeepSeek key could not be loaded."
        case .http(401), .http(403): "DeepSeek rejected the saved key."
        case .http(402): "DeepSeek has insufficient credit."
        case .http(429): "DeepSeek is busy or rate limited. Try again shortly."
        case .http(let code): "DeepSeek returned HTTP \(code). Try again."
        case .invalidStream: "DeepSeek returned an unreadable response."
        case .interruptedStream: "The reply connection ended early. Please try again."
        }
    }
}

public enum StreamEvent: Equatable, Sendable {
    case text(String), done, ignore
}

public struct DeepSeekProvider: ReplyProvider {
    private let key: String
    private let tools: (any MacToolExecutor)?
    public init(key: String, tools: (any MacToolExecutor)? = nil) { self.key = key; self.tools = tools }

    public func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                do {
                    guard !key.isEmpty else { throw ProviderError.missingKey }
                    let system = "You are Mercy, a friendly native Mac assistant. Use the provided tools to inspect real apps and files and act on the user's request. Use actual installed app names and paths, never invented ones. If an app is ambiguous, relay the choices and wait for the user; do not choose for them. Never claim success before a tool confirms it. Read files only when relevant to the current request; never search for credentials. File writes show a preview and wait for the user's approval. You cannot bypass macOS permissions. Unsupported actions must be described honestly. Voice arrives as text. Keep replies brief and natural unless asked for detail."
                    var history: [[String: Any]] = [["role": "system", "content": system]] + messages.suffix(20).map {
                        ["role": $0.isUser ? "user" : "assistant", "content": $0.text]
                    }
                    let definitions = try await tools?.definitions()
                    for _ in 0..<6 {
                        try Task.checkCancellation()
                        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
                        request.httpMethod = "POST"
                        request.timeoutInterval = 60
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        var body: [String: Any] = [
                            "model": "deepseek-flash", "stream": true, "max_tokens": 2000,
                            "thinking": ["type": "disabled"], "messages": history,
                        ]
                        if let definitions { body["tools"] = try JSONSerialization.jsonObject(with: definitions) }
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidStream }
                        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
                        var calls: [Int: ToolCall] = [:]
                        var answer = ""
                        var finished = false
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            for fragment in try Self.toolFragments(line: line) {
                                guard fragment.index >= 0 && fragment.index < 20 else { throw ProviderError.invalidStream }
                                calls[fragment.index, default: ToolCall()].append(fragment)
                            }
                            switch try Self.parse(line: line) {
                            case .text(let text): answer += text; continuation.yield(text)
                            case .done: finished = true
                            case .ignore: continue
                            }
                            if finished { break }
                        }
                        guard finished else { throw ProviderError.interruptedStream }
                        guard !calls.isEmpty else { continuation.finish(); return }
                        guard let tools else { throw ProviderError.invalidStream }
                        let ordered = calls.keys.sorted().compactMap { calls[$0] }
                        guard ordered.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }) else { throw ProviderError.invalidStream }
                        if !answer.isEmpty { continuation.yield("\n\n") }
                        history.append(["role": "assistant", "content": answer,
                            "tool_calls": ordered.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }])
                        for call in ordered {
                            try Task.checkCancellation()
                            let result = try await tools.execute(name: call.name, arguments: call.arguments)
                            try Task.checkCancellation()
                            history.append(["role": "tool", "tool_call_id": call.id, "content": result])
                        }
                    }
                    throw ProviderError.toolLimit
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func toolFragments(line: String) throws -> [ToolFragment] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return [] }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { var tool_calls: [ToolFragment]? }
                var delta: Delta?
            }
            var choices: [Choice]?
        }
        return try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)).choices?.first?.delta?.tool_calls ?? []
    }

    public static func parse(line: String) throws -> StreamEvent {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil else { throw ProviderError.invalidStream }
        let choices = object["choices"] as? [[String: Any]] ?? []
        let delta = choices.first?["delta"] as? [String: Any]
        if let text = delta?["content"] as? String, !text.isEmpty { return .text(text) }
        return .ignore
    }
}
