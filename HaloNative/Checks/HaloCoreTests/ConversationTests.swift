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

private actor RecordingTools: MacToolExecutor {
    var executed: [String] = []
    nonisolated func definitions() async throws -> Data {
        Data(#"[{"type":"function","function":{"name":"open_app","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},{"type":"function","function":{"name":"list_apps","parameters":{"type":"object","properties":{}}}},{"type":"function","function":{"name":"inspect_screen","parameters":{"type":"object","properties":{}}}},{"type":"function","function":{"name":"browser_media","parameters":{"type":"object","properties":{"action":{"type":"string","enum":["play","pause"]},"tab_id":{"type":"integer"},"seconds":{"type":"number"},"muted":{"type":"boolean"}},"required":["action"]}}}]"#.utf8)
    }
    func execute(name: String, arguments: String) async throws -> String {
        executed.append("\(name) \(arguments)")
        return name == "inspect_screen" ? #"{"ok":true,"mime_type":"image/jpeg","image_base64":"aW1hZ2U="}"# : #"{"ok":true}"#
    }
}

/// Plays back scripted rounds and records what the loop sends back.
private final class ScriptedBackend: ModelBackend, @unchecked Sendable {
    struct Limit: Error {}
    let rounds: [RoundOutcome]
    var outputs: [[ToolOutput]] = []
    init(_ rounds: [RoundOutcome]) { self.rounds = rounds }
    var actionLimitError: any Error { Limit() }
    var unavailableToolError: any Error { Limit() }
    func startTurn(messages: [Message], tools: Data?) throws -> any ModelTurn { Turn(backend: self) }
    final class Turn: ModelTurn {
        let backend: ScriptedBackend
        var index = 0
        init(backend: ScriptedBackend) { self.backend = backend }
        func round(emit: @escaping @Sendable (String) -> Void, status: @escaping @Sendable (String) async -> Void) async throws -> RoundOutcome {
            defer { index += 1 }
            return index < backend.rounds.count ? backend.rounds[index] : .answered
        }
        func append(_ outputs: [ToolOutput]) { backend.outputs.append(outputs) }
    }
}

private func calls(_ list: [(String, String)]) -> RoundOutcome {
    .toolCalls(text: "", calls: list.enumerated().map { ToolRequest(id: "c\($0.offset)", name: $0.element.0, arguments: $0.element.1) })
}

func agentLoopValidatesAndRunsTools() async throws {
    let tools = RecordingTools()
    let validator = ToolValidator(definitions: try await tools.definitions())!
    let valid = try validator.check(name: "open_app", arguments: #"{"name":"Notes"}"#).get()
    precondition(valid == #"{"name":"Notes"}"#)
    let blank = try validator.check(name: "list_apps", arguments: "  ").get()
    precondition(blank == "{}")
    _ = try validator.check(name: "browser_media", arguments: #"{"action":"pause","tab_id":3.0,"seconds":1.5,"muted":true}"#).get()
    _ = try validator.check(name: "browser_media", arguments: #"{"action":"pause","tab_id":null}"#).get()
    for (name, arguments, expected) in [
        ("launch_app", "{}", "no tool named"), ("open_app", "{}", "missing required name"), ("open_app", "{name:", "not valid JSON"),
        ("open_app", #"{"name":3}"#, "must be a string"), ("open_app", #"{"name":"Notes","x":1}"#, "unknown argument x"),
        ("browser_media", #"{"action":"stop"}"#, "must be one of play, pause"), ("browser_media", #"{"action":"play","tab_id":2.5}"#, "whole number"),
        ("browser_media", #"{"action":"play","tab_id":true}"#, "whole number"), ("browser_media", #"{"action":"play","muted":1}"#, "true or false"),
    ] {
        guard case .failure(let problem) = validator.check(name: name, arguments: arguments) else { preconditionFailure("\(name) \(arguments) passed") }
        precondition(problem.message.contains(expected), problem.message)
    }

    // A rejected call is not executed; the model gets the problem back and its corrected call runs.
    let backend = ScriptedBackend([calls([("open_app", "{}")]), calls([("open_app", #"{"name":"Notes"}"#), ("inspect_screen", "")])])
    var reply = ""
    for try await delta in AgentLoop(backend: backend, tools: tools).reply(to: [Message(isUser: true, text: "open notes")]) { reply += delta }
    let executed = await tools.executed
    precondition(executed == [#"open_app {"name":"Notes"}"#, "inspect_screen {}"], "\(executed)")
    precondition(backend.outputs.count == 2 && backend.outputs[0][0].text.contains("missing required name") && backend.outputs[0][0].text.contains(#""ok":false"#))
    precondition(backend.outputs[1][1].imageURLs == ["data:image/jpeg;base64,aW1hZ2U="] && !backend.outputs[1][1].text.contains("image_base64"))

    // Repeated all-invalid rounds stop the request; the round limit still applies.
    let stuck = ScriptedBackend(Array(repeating: calls([("launch_app", "{}")]), count: 5))
    var stopped = false
    do { for try await _ in AgentLoop(backend: stuck, tools: tools).reply(to: [Message(isUser: true, text: "x")]) {} } catch is ToolValidator.RepeatedInvalidCalls { stopped = true }
    precondition(stopped && stuck.outputs.count == 2)
    let endless = ScriptedBackend(Array(repeating: calls([("list_apps", "{}")]), count: AgentLoop.maxRounds + 1))
    var limited = false
    do { for try await _ in AgentLoop(backend: endless, tools: tools).reply(to: [Message(isUser: true, text: "x")]) {} } catch is ScriptedBackend.Limit { limited = true }
    precondition(limited && endless.outputs.count == AgentLoop.maxRounds)
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
        let imageParts = AgentLoop.screenAttachment(result: imageResult)
        precondition(imageParts != nil && !imageParts!.toolText.contains("image_base64"))
        precondition(imageParts!.imageURL == "data:image/jpeg;base64,aW1hZ2U=")
        precondition(AgentLoop.screenAttachment(result: #"{"ok":false,"denied":true}"#) == nil)
        precondition(AgentLoop.screenAttachment(result: #"{"ok":true,"mime_type":"text/plain","image_base64":"aW1hZ2U="}"#) == nil)
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
        let allTools = Data(#"[{"type":"function","function":{"name":"list_apps"}},{"type":"function","function":{"name":"open_app"}},{"type":"function","function":{"name":"keypress"}},{"type":"function","function":{"name":"window_layout"}},{"type":"function","function":{"name":"read_browser_tab"}}]"#.utf8)
        let browserTools = try JSONSerialization.jsonObject(with: ToolScope.definitions(allTools, for: "open youtube.com")) as? [[String: Any]] ?? []
        precondition(browserTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } == ["read_browser_tab"])
        precondition(ToolScope.definitions(allTools, for: "open Stremio") == allTools)
        precondition(ToolScope.definitions(allTools, for: "open youtube and put the window on the left half") == allTools)
        print("PASS: browser-only requests drop Mac app-discovery and UI-control tools; Mac and mixed requests keep every tool")
        try await agentLoopValidatesAndRunsTools()
        print("PASS: tool calls are validated before running; rejected calls return the problem to the model; invalid streaks and the round limit stop the loop")
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
