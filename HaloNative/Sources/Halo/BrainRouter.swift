import Foundation
import HaloCore

@MainActor
final class BrainRouter: ReplyProvider {
    let auth: ChatGPTAuth
    let tools: MacTools?
    let deepSeekKey: String
    init(auth: ChatGPTAuth, tools: MacTools?, deepSeekKey: String) { self.auth = auth; self.tools = tools; self.deepSeekKey = deepSeekKey }
    nonisolated func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let provider: any ReplyProvider
                    if auth.provider == "chatgpt" {
                        let (model, token) = try await auth.modelAndToken()
                        provider = ChatGPTProvider(token: token, model: model, tools: tools)
                    } else { provider = DeepSeekProvider(key: deepSeekKey, tools: tools) }
                    try Task.checkCancellation()
                    for try await delta in provider.reply(to: messages) { try Task.checkCancellation(); continuation.yield(delta) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
