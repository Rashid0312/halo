import Foundation
import HaloCore

private struct ControlledProvider: ReplyProvider {
    let stream: AsyncThrowingStream<String, Error>
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> { stream }
}

@MainActor
func stoppedTurnCannotAppendLateOutput() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let conversation = Conversation(provider: ControlledProvider(stream: stream))
    conversation.send("Hello")
    conversation.stop()
    continuation.yield("stale output")
    continuation.finish()
    await Task.yield()
    precondition(!conversation.isResponding)
    precondition(conversation.messages.last?.text == "")
    precondition(conversation.status == "Stopped")
}

@MainActor
func clearCancelsPendingReply() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let conversation = Conversation(provider: ControlledProvider(stream: stream))
    conversation.send("Hello")
    conversation.clear()
    continuation.yield("stale output")
    continuation.finish()
    await Task.yield()
    precondition(conversation.messages.isEmpty)
    precondition(!conversation.isResponding)
}

@MainActor
func blankInputDoesNotStartTurn() {
    let conversation = Conversation()
    conversation.send("  \n ")
    precondition(conversation.messages.isEmpty)
    precondition(!conversation.isResponding)
}

@main
struct CoreChecks {
    @MainActor static func main() async throws {
        try await stoppedTurnCannotAppendLateOutput()
        print("PASS: stopped turn rejects late output")
        try await clearCancelsPendingReply()
        print("PASS: clearing cancels pending reply")
        let keepalive = try DeepSeekProvider.parse(line: ": keepalive")
        precondition(keepalive == .ignore)
        let done = try DeepSeekProvider.parse(line: "data: [DONE]")
        precondition(done == .done)
        let unicode = #"data: {"choices":[{"delta":{"content":"Hej 👋"}}]}"#
        let parsed = try DeepSeekProvider.parse(line: unicode)
        precondition(parsed == .text("Hej 👋"))
        var rejectedMalformed = false
        do { _ = try DeepSeekProvider.parse(line: "data: broken") } catch { rejectedMalformed = true }
        precondition(rejectedMalformed)
        print("PASS: streaming parser handles text, Unicode, keepalive, completion, and malformed data")
        blankInputDoesNotStartTurn()
        print("PASS: blank input is ignored")
    }
}
