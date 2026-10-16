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

@MainActor @Observable
public final class Conversation {
    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false
    public private(set) var status: String
    public let providerName: String
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
        stop()
        let id = UUID()
        turnID = id
        messages.append(Message(isUser: true, text: prompt))
        let stream = response(messages)
        messages.append(Message(isUser: false, text: ""))
        let replyIndex = messages.count - 1
        isResponding = true
        status = "Responding…"
        task = Task { [weak self] in
            do {
                for try await delta in stream {
                    guard let self, self.turnID == id, !Task.isCancelled else { return }
                    self.messages[replyIndex].text += delta
                }
                guard let self, self.turnID == id else { return }
                let answer = self.messages[replyIndex].text
                self.finish(status: "Ready · \(self.providerName)")
                self.onReply?(answer)
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
