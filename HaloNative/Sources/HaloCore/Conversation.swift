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

public struct ActivityStep: Identifiable, Sendable, Equatable {
    public enum State: Sendable { case active, complete, failed }
    public let id: UUID
    public var title: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var state: State

    public init(title: String, startedAt: Date = Date(), state: State = .active) {
        id = UUID(); self.title = title; self.startedAt = startedAt; self.state = state
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

    public nonisolated static func looksLikeWebResearch(_ input: String) -> Bool {
        let text = input.lowercased()
        return ["search", "look up", "check if", "find out", "latest", "today", "news", "release date", "out yet", "is out", "current web"].contains { text.contains($0) }
    }

    public private(set) var messages: [Message] = []
    public private(set) var isResponding = false
    public private(set) var status: String
    public private(set) var activity = ""
    public private(set) var activitySteps: [ActivityStep] = []
    public private(set) var providerName: String
    public private(set) var lastPrompt = ""
    @ObservationIgnored public private(set) var streamUpdateCount = 0
    public let isDemo: Bool
    @ObservationIgnored public var onReply: ((String) -> Void)?
    @ObservationIgnored public var onReplyStart: (() -> Void)?
    @ObservationIgnored public var onReplyDelta: ((String) -> Void)?
    @ObservationIgnored public var onStop: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var turnID: UUID?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastProgressAt = Date()
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

    public func retry() {
        guard !lastPrompt.isEmpty else { return }
        send(lastPrompt)
    }

    public func reportActivity(_ title: String) {
        guard isResponding, !title.isEmpty else { return }
        completeActiveStep()
        activity = title
        activitySteps.append(ActivityStep(title: title))
        if activitySteps.count > 8 { activitySteps.removeFirst(activitySteps.count - 8) }
        lastProgressAt = Date()
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
        lastPrompt = prompt
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
        activitySteps = []
        reportActivity(Self.looksLikeWebResearch(prompt) ? "Searching and reading sources…" : "Contacting \(providerName)…")
        startWatchdog(turnID: id)
        onReplyStart?()
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
                        if self.messages[replyIndex].text.isEmpty { self.reportActivity("Writing the answer…") }
                        let remaining = Self.maximumReplyCharacters - self.messages[replyIndex].text.count
                        guard remaining > 0 else {
                            producer.cancel()
                            self.finish(status: "Reply stopped · maximum length reached")
                            return
                        }
                        let accepted = String(batch.text.prefix(remaining))
                        self.messages[replyIndex].text += accepted
                        self.streamUpdateCount += 1
                        self.onReplyDelta?(accepted)
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
        watchdog?.cancel()
        watchdog = nil
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
        completeActiveStep()
        activity = ""
        watchdog?.cancel()
        watchdog = nil
        self.status = status
        isResponding = false
        turnID = nil
        task = nil
    }

    private func completeActiveStep() {
        guard let index = activitySteps.indices.last, activitySteps[index].state == .active else { return }
        activitySteps[index].state = .complete
        activitySteps[index].finishedAt = Date()
    }

    private func startWatchdog(turnID id: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.turnID == id, self.isResponding else { return }
                let idle = Date().timeIntervalSince(self.lastProgressAt)
                if idle >= 20, !self.activity.contains("taking longer") {
                    self.activity = "Still waiting — this is taking longer than expected…"
                    if let index = self.activitySteps.indices.last, self.activitySteps[index].state == .active {
                        self.activitySteps[index].title = self.activity
                    }
                }
            }
        }
    }
}
