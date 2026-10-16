import Foundation
import Observation

public protocol ReplyProvider: Sendable {
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error>
}

/// Offline transport for exercising streaming and cancellation without credentials.
public struct DemoProvider: ReplyProvider {
    public init() {}

    public func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let prompt = messages.last?.text ?? ""
                let reply = "You said: “\(prompt)”\n\nHalo’s native conversation panel is running. This is a demo response; no AI service is connected yet."
                do {
                    for word in reply.split(separator: " ") {
                        try await Task.sleep(for: .milliseconds(65))
                        try Task.checkCancellation()
                        continuation.yield(String(word) + " ")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct Message: Identifiable, Sendable {
    public let id = UUID()
    public let isUser: Bool
    public var text: String
    public init(isUser: Bool, text: String) {
        self.isUser = isUser
        self.text = text
    }
}

private actor StreamBuffer {
    private let limit: Int
    private var pending = ""
    private var completion: Result<Void, Error>?
    private var acceptedCharacters = 0
    private var exceededLimit = false

    init(limit: Int) { self.limit = limit }

    func append(_ text: String) {
        guard !exceededLimit else { return }
        let remaining = limit - acceptedCharacters
        if text.count > remaining {
            pending += String(text.prefix(remaining))
            acceptedCharacters += remaining
            exceededLimit = true
        } else {
            pending += text
            acceptedCharacters += text.count
        }
    }
    func finish(_ result: Result<Void, Error>) { completion = result }

    func drain() -> (text: String, completion: Result<Void, Error>?, exceededLimit: Bool) {
        let text = pending
        pending = ""
        return (text, completion, exceededLimit)
    }
}

@MainActor @Observable
public final class Conversation {
    public static let maximumMessages = 40
    public static let maximumInputCharacters = 16_000
    public static let maximumReplyCharacters = 64_000
    public static let maximumRetainedCharacters = 160_000
    public static let streamRenderInterval = Duration.milliseconds(50)

    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false
    public private(set) var status: String
    public private(set) var providerName: String
    @ObservationIgnored public private(set) var streamUpdateCount = 0
    public let isDemo: Bool
    @ObservationIgnored public var onReply: ((String) -> Void)?
    @ObservationIgnored public var onStop: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var turnID: UUID?
    private let provider: any ReplyProvider

    public init(provider: any ReplyProvider = DemoProvider(), providerName: String = "Demo mode") {
        self.provider = provider
        self.providerName = providerName
        self.isDemo = providerName == "Demo mode"
        self.status = "Ready · \(providerName)"
    }

    public func changeProviderName(_ name: String) {
        stop()
        providerName = name
        status = "Ready · \(name)"
    }

    public func send(_ input: String) {
        begin(input) { [provider] history in provider.reply(to: history) }
    }

    public func performAction(_ input: String, action: @escaping @MainActor @Sendable () async throws -> String) {
        begin(input) { _ in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do { continuation.yield(try await action()); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private func begin(_ input: String, response: ([Message]) -> AsyncThrowingStream<String, Error>) {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard prompt.count <= Self.maximumInputCharacters else {
            status = "Message is too long · maximum \(Self.maximumInputCharacters) characters"
            return
        }
        stop()
        let retainedCount = Self.maximumMessages - 2
        if messages.count > retainedCount { messages.removeFirst(messages.count - retainedCount) }
        let historyBudget = max(0, Self.maximumRetainedCharacters - prompt.count - Self.maximumReplyCharacters)
        var historyCharacters = messages.reduce(into: 0) { $0 += $1.text.count }
        while historyCharacters > historyBudget, let first = messages.first {
            historyCharacters -= first.text.count
            messages.removeFirst()
        }
        let id = UUID()
        turnID = id
        messages.append(Message(isUser: true, text: prompt))
        let stream = response(messages)
        messages.append(Message(isUser: false, text: ""))
        let replyIndex = messages.count - 1
        streamUpdateCount = 0
        isResponding = true
        status = "Responding…"
        task = Task { [weak self] in
            let buffer = StreamBuffer(limit: Self.maximumReplyCharacters)
            let producer = Task.detached(priority: .userInitiated) {
                do {
                    for try await delta in stream {
                        try Task.checkCancellation()
                        await buffer.append(delta)
                    }
                    await buffer.finish(.success(()))
                } catch {
                    await buffer.finish(.failure(error))
                }
            }
            defer { producer.cancel() }
            do {
                while true {
                    try await Task.sleep(for: Self.streamRenderInterval)
                    try Task.checkCancellation()
                    let batch = await buffer.drain()
                    guard let self, self.turnID == id else { return }
                    if !batch.text.isEmpty {
                        let remaining = Self.maximumReplyCharacters - self.messages[replyIndex].text.count
                        guard remaining > 0 else {
                            producer.cancel()
                            self.finish(status: "Reply stopped · maximum length reached")
                            return
                        }
                        self.messages[replyIndex].text += String(batch.text.prefix(remaining))
                        self.streamUpdateCount += 1
                    }
                    if batch.exceededLimit {
                        producer.cancel()
                        self.finish(status: "Reply stopped · maximum length reached")
                        return
                    }
                    guard let completion = batch.completion else { continue }
                    switch completion {
                    case .success:
                        let answer = self.messages[replyIndex].text
                        self.finish(status: "Ready · \(self.providerName)")
                        self.onReply?(answer)
                    case .failure(let error):
                        throw error
                    }
                    return
                }
            } catch {
                guard let self, self.turnID == id else { return }
                self.finish(status: error is CancellationError ? "Stopped" : "Reply failed: \(error.localizedDescription)")
            }
        }
    }

    public func stop() {
        onStop?()
        turnID = nil
        task?.cancel()
        task = nil
        if isResponding { status = "Stopped" }
        isResponding = false
    }

    public func clear() {
        stop()
        messages.removeAll()
        status = "Ready · \(providerName)"
    }

    private func finish(status: String) {
        self.status = status
        isResponding = false
        turnID = nil
        task = nil
    }
}
