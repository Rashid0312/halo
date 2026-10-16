import Foundation

public enum ProviderError: LocalizedError {
    case missingKey, http(Int), invalidStream, interruptedStream
    public var errorDescription: String? {
        switch self {
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
    public init(key: String) { self.key = key }

    public func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                do {
                    guard !key.isEmpty else { throw ProviderError.missingKey }
                    var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let system = "You are Halo, a friendly Mac assistant. Answer clearly and concisely. This native version currently supports conversation only: do not claim to have accessed the screen, heard audio, or performed Mac actions."
                    let history = messages.suffix(20).map { ["role": $0.isUser ? "user" : "assistant", "content": $0.text] }
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": "deepseek-flash", "stream": true, "max_tokens": 2000,
                        "thinking": ["type": "disabled"],
                        "messages": [["role": "system", "content": system]] + history,
                    ])
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidStream }
                    guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        switch try Self.parse(line: line) {
                        case .text(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .ignore: continue
                        }
                    }
                    throw ProviderError.interruptedStream
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
