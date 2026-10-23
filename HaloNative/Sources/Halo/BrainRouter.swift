import Foundation
import HaloCore

/// What the brain needs to start a request, readable off the main thread.
/// ChatGPTAuth publishes it whenever the provider, model, or token changes.
final class BrainSnapshot: @unchecked Sendable {
    struct State: Sendable {
        var provider = "deepseek"
        /// Empty until the account's model list has loaded and validated it.
        var model = ""
        var accessToken = ""
        var expiresAt = Date.distantPast
    }
    private let lock = NSLock()
    private var state = State()
    var value: State { lock.withLock { state } }
    func update(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }
}

/// Chooses the brain per request without waiting on the main thread: a UI
/// stall must never hold up Mercy's work. Only a missing model list or a
/// token near expiry hops to ChatGPTAuth on the main actor.
final class BrainRouter: ReplyProvider, Sendable {
    let auth: ChatGPTAuth
    let tools: MacTools?
    let deepSeekKey: DeepSeekKey
    init(auth: ChatGPTAuth, tools: MacTools?, deepSeekKey: DeepSeekKey) { self.auth = auth; self.tools = tools; self.deepSeekKey = deepSeekKey }
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [auth, tools, deepSeekKey] in
                do {
                    let provider: any ReplyProvider
                    let snapshot = auth.snapshot.value
                    if snapshot.provider == "chatgpt" {
                        TimingLog.shared.mark("brain: ChatGPT token")
                        let model: String, token: String
                        if !snapshot.model.isEmpty, !snapshot.accessToken.isEmpty, snapshot.expiresAt.timeIntervalSinceNow > 120 {
                            (model, token) = (snapshot.model, snapshot.accessToken)
                        } else {
                            (model, token) = try await auth.modelAndToken()
                        }
                        TimingLog.shared.mark("brain: ChatGPT token ready")
                        provider = ChatGPTProvider(token: token, model: model, tools: tools)
                    } else { provider = DeepSeekProvider(key: deepSeekKey.value, tools: tools) }
                    try Task.checkCancellation()
                    for try await delta in provider.reply(to: messages) { try Task.checkCancellation(); continuation.yield(delta) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
