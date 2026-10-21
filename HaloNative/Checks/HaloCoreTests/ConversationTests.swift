import Foundation
import HaloCore

private struct ControlledProvider: ReplyProvider {
    let stream: AsyncThrowingStream<String, Error>
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> { stream }
}

private struct ImmediateProvider: ReplyProvider {
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }
}

private struct FixedProvider: ReplyProvider {
    let text: String
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(text)
            continuation.finish()
        }
    }
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

@MainActor
func streamedOutputIsBatchedAndBounded() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let conversation = Conversation(provider: ControlledProvider(stream: stream))
    conversation.send("Hello")
    for _ in 0..<1_000 { continuation.yield("x") }
    continuation.finish()
    try await Task.sleep(for: .milliseconds(180))
    precondition(conversation.messages.last?.text.count == 1_000)
    precondition(!conversation.isResponding)
    precondition(conversation.streamUpdateCount < 10)

    let oversized = String(repeating: "x", count: Conversation.maximumInputCharacters + 1)
    conversation.send(oversized)
    precondition(conversation.messages.count == 2)
    precondition(conversation.status.contains("too long"))

    let (largeStream, largeContinuation) = AsyncThrowingStream<String, Error>.makeStream()
    let largeConversation = Conversation(provider: ControlledProvider(stream: largeStream))
    largeConversation.send("Hello")
    largeContinuation.yield(String(repeating: "y", count: Conversation.maximumReplyCharacters + 1_000))
    largeContinuation.finish()
    try await Task.sleep(for: .milliseconds(180))
    precondition(largeConversation.messages.last?.text.count == Conversation.maximumReplyCharacters)
    precondition(!largeConversation.isResponding)
    precondition(largeConversation.status.contains("maximum length"))
}

@MainActor
func conversationHistoryIsBounded() async throws {
    let conversation = Conversation(provider: ImmediateProvider())
    for index in 0..<(Conversation.maximumMessages + 10) {
        conversation.send("message \(index)")
        while conversation.isResponding { try await Task.sleep(for: .milliseconds(20)) }
    }
    precondition(conversation.messages.count <= Conversation.maximumMessages)

    let largeReply = String(repeating: "z", count: 50_000)
    let largeConversation = Conversation(provider: FixedProvider(text: largeReply))
    for index in 0..<6 {
        largeConversation.send("large message \(index)")
        while largeConversation.isResponding { try await Task.sleep(for: .milliseconds(20)) }
    }
    let retainedCharacters = largeConversation.messages.reduce(into: 0) { $0 += $1.text.count }
    precondition(retainedCharacters <= Conversation.maximumRetainedCharacters)
}

@MainActor
func activityTimelineTracksProgress() async throws {
    let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
    let conversation = Conversation(provider: ControlledProvider(stream: stream), providerName: "Test brain")
    conversation.send("research this")
    precondition(conversation.activity == "Searching and reading sources…")
    precondition(conversation.activitySteps.count == 1)
    conversation.reportActivity("Searching the web…")
    precondition(conversation.activitySteps.count == 2)
    precondition(conversation.activitySteps.first?.state == .complete)
    continuation.yield("answer")
    continuation.finish()
    try await Task.sleep(for: .milliseconds(120))
    precondition(!conversation.isResponding)
    precondition(conversation.activity.isEmpty)
    precondition(conversation.activitySteps.last?.state == .complete)
    precondition(conversation.lastPrompt == "research this")
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
        let imageResult = #"{"ok":true,"mime_type":"image/jpeg","image_base64":"aW1hZ2U=","scope":"test"}"#
        let imageParts = DeepSeekProvider.screenAttachment(result: imageResult)
        precondition(imageParts != nil && !imageParts!.toolText.contains("image_base64"))
        let imageURL = (imageParts!.imageContent.first?["image_url"] as? [String: String])?["url"]
        precondition(imageURL == "data:image/jpeg;base64,aW1hZ2U=")
        precondition(DeepSeekProvider.screenAttachment(result: #"{"ok":false,"denied":true}"#) == nil)
        precondition(DeepSeekProvider.screenAttachment(result: #"{"ok":true,"mime_type":"text/plain","image_base64":"aW1hZ2U="}"#) == nil)
        print("PASS: screenshots become image content, base64 is removed from tool text, and declined/unsupported images are rejected")
        let responseDelta = try ChatGPTProvider.event(#"data: {"type":"response.output_text.delta","delta":"Hello 👋"}"#)
        precondition(responseDelta?["delta"] as? String == "Hello 👋")
        let responseKeepalive = try ChatGPTProvider.event(": keepalive")
        precondition(responseKeepalive == nil)
        let responseDone = try ChatGPTProvider.event("data: [DONE]")
        precondition(responseDone == nil)
        let completedMessage = try ChatGPTProvider.event(#"data: {"type":"response.output_item.done","item":{"type":"message","status":"completed"}}"#)
        precondition(ChatGPTProvider.completesVisibleAnswer(completedMessage))
        let completedTool = try ChatGPTProvider.event(#"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"list_apps","arguments":"{}"}}"#)
        precondition(!ChatGPTProvider.completesVisibleAnswer(completedTool))
        let limit = ChatGPTProvider.apiError(Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8), status: 429)
        precondition(limit.localizedDescription.contains("usage limit"))
        print("PASS: ChatGPT Responses text parsing, keepalive/completion handling, and plan-limit errors")
        let firstFragment = try DeepSeekProvider.toolFragments(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"open_app","arguments":"{\"name\":"}}]}}]}"#)
        let lastFragment = try DeepSeekProvider.toolFragments(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Stremio\"}"}}]}}]}"#)
        var call = ToolCall()
        (firstFragment + lastFragment).forEach { call.append($0) }
        precondition(call.id == "call_1" && call.name == "open_app" && call.arguments == #"{"name":"Stremio"}"#)
        print("PASS: streamed tool arguments are assembled before execution")
        var endpoint = RequestEndpoint()
        precondition(!endpoint.observe(sampleCount: 16000, speechDetected: true))
        precondition(!endpoint.observe(sampleCount: 32000, speechDetected: false))
        endpoint.confirmRequest()
        precondition(!endpoint.observe(sampleCount: 16000, speechDetected: true))
        precondition(endpoint.observe(sampleCount: 16000, speechDetected: false))
        var abandoned = RequestEndpoint()
        precondition(abandoned.observe(sampleCount: 16000 * 9, speechDetected: false))
        precondition(WakeTranscript.request(from: "Hey Mercy.") == "")
        precondition(WakeTranscript.request(from: "Hey, Merci, open Stremio.") == "open Stremio.")
        precondition(WakeTranscript.request(from: "open Stremio") == nil)
        print("PASS: wake-only pauses stay open until request speech; silence timeout and wake confirmation remain bounded")
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
        for prompt in ["open netflix and tell me what I watched last", "close all my tabs except Netflix", "go to example.com",
                       "read https://example.org/a", "pause the YouTube video", "what's on this web page?", "zoom in on the site"] {
            precondition(ToolScope.isBrowserRequest(prompt), prompt)
        }
        for prompt in ["open Stremio", "arrange my windows side by side", "make a table in Numbers", "what time is it?"] {
            precondition(!ToolScope.isBrowserRequest(prompt), prompt)
        }
        let allTools = Data(#"[{"type":"function","function":{"name":"list_apps"}},{"type":"function","function":{"name":"open_app"}},{"type":"function","function":{"name":"read_browser_tab"}}]"#.utf8)
        let browserTools = try JSONSerialization.jsonObject(with: ToolScope.definitions(allTools, for: "open youtube.com")) as? [[String: Any]] ?? []
        precondition(browserTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["read_browser_tab"])
        precondition(ToolScope.definitions(allTools, for: "open Stremio") == allTools)
        print("PASS: browser requests drop Mac app-discovery tools; other requests keep every tool")
        blankInputDoesNotStartTurn()
        print("PASS: blank input is ignored")
        try await streamedOutputIsBatchedAndBounded()
        print("PASS: streamed output is rendered in bounded batches and input/reply sizes are capped")
        try await conversationHistoryIsBounded()
        print("PASS: rendered conversation rows and total retained text are bounded")
        try await activityTimelineTracksProgress()
        print("PASS: response activity stages are timed, retained, and completed")
    }
}
