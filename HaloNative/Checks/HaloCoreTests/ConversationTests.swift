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
        let firstFragment = try DeepSeekProvider.toolFragments(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"open_app","arguments":"{\"name\":"}}]}}]}"#)
        let lastFragment = try DeepSeekProvider.toolFragments(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Stremio\"}"}}]}}]}"#)
        var call = ToolCall()
        (firstFragment + lastFragment).forEach { call.append($0) }
        precondition(call.id == "call_1" && call.name == "open_app" && call.arguments == #"{"name":"Stremio"}"#)
        print("PASS: streamed tool arguments are assembled before execution")
        let stremio = InstalledApp(id: "com.example.stremio", name: "Stremio", path: "/Applications/Stremio.app")
        let safari = InstalledApp(id: "com.apple.Safari", name: "Safari", path: "/Applications/Safari.app")
        let apps = [stremio, safari]
        precondition(AppResolver.resolve("streamio", apps: apps) == .match(stremio))
        precondition(AppResolver.resolve("Streamo.", apps: apps) == .match(stremio))
        precondition(AppResolver.launchTarget(in: "open Streamo.") == "Streamo")
        precondition(AppResolver.resolve("STREAM IO", apps: apps) == .match(stremio))
        precondition(AppResolver.resolve("streamio", apps: [safari]) == .missing)
        precondition(AppResolver.resolve("safary", apps: apps) == .suggestions([safari]))
        precondition(AppResolver.resolve("my movies", apps: apps, aliases: ["my movies": stremio.id]) == .match(stremio))
        precondition(AppResolver.launchTarget(in: "could you open streamio please?") == "streamio")
        precondition(AppResolver.launchTarget(in: "open Safari and Stremio") == nil)
        precondition(AppResolver.speechVocabulary(apps: apps).contains("Stremio"))
        print("PASS: app resolution uses installed bundles, aliases, uncertainty, and speech vocabulary")
        blankInputDoesNotStartTurn()
        print("PASS: blank input is ignored")
    }
}
