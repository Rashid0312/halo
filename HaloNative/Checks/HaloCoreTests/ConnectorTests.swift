import Foundation
import HaloCore

private let fakeServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Fixtures/FakeMCPServer.py").standardizedFileURL.path

/// Hands out "bad" until asked to refresh, then "good", to exercise refresh on 401.
private actor FakeTokens: ConnectorTokenSource {
    let connected: Set<String>
    private(set) var refreshes = 0
    init(_ connected: Set<String>) { self.connected = connected }
    func token(for connector: String, forceRefresh: Bool) async throws -> String? {
        guard connected.contains(connector) else { return nil }
        if forceRefresh { refreshes += 1 }
        return refreshes > 0 ? "good" : "bad"
    }
    func setting(_ name: String, for connector: String) async -> String? { nil }
}

private func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

func sseEventsAreJoined() {
    var reader = SSEEventReader()
    precondition(reader.feed(": keepalive") == nil)
    precondition(reader.feed("event: message") == nil)
    precondition(reader.feed(#"data: {"a":"#) == nil)
    let joined = reader.feed(#"data: 1}"#)
    precondition(joined.map { object(String(decoding: $0, as: UTF8.self))["a"] as? Int } == 1)
    let single = reader.feed(#"data:{"b":2}"#)
    precondition(single.map { object(String(decoding: $0, as: UTF8.self))["b"] as? Int } == 2)
    precondition(reader.feed("") == nil && reader.finish() == nil)
}

/// Notion's notion-create-pages: `properties` is a map of any names to a
/// string, number, list of strings, or null. Halo's own strict schemas are unchanged.
func validatorAcceptsOpenMaps() {
    let definitions = Data(#"""
    [{"type":"function","function":{"name":"create_pages","parameters":{"type":"object","properties":{
      "pages":{"type":"array","items":{"type":"object","properties":{
        "properties":{"type":"object","propertyNames":{"type":"string"},
                      "additionalProperties":{"anyOf":[{"type":"string"},{"type":"number"},{"type":"array","items":{"type":"string"}},{"type":"null"}]}},
        "content":{"type":"string"}}}}},"required":["pages"]}}},
     {"type":"function","function":{"name":"open_app","parameters":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
     {"type":"function","function":{"name":"tagged","parameters":{"type":"object","properties":{"tags":{"type":"object","additionalProperties":true}}}}}]
    """#.utf8)
    let validator = ToolValidator(definitions: definitions)!
    let ok = validator.check(name: "create_pages", arguments: #"{"pages":[{"properties":{"title":"Hey Mercy","Score":3,"Tags":["a"]},"content":"stay strong"}]}"#)
    if case .failure(let problem) = ok { preconditionFailure("open map rejected: \(problem.message)") }
    guard case .failure = validator.check(name: "create_pages", arguments: #"{"pages":[{"properties":{"title":{"nested":true}}}]}"#) else {
        preconditionFailure("a value matching none of the anyOf forms was accepted")
    }
    guard case .failure = validator.check(name: "create_pages", arguments: #"{"pages":[{"bogus":1}]}"#) else {
        preconditionFailure("a closed object accepted an unknown key")
    }
    guard case .failure = validator.check(name: "open_app", arguments: #"{"name":"Notes","extra":1}"#) else {
        preconditionFailure("Halo's own tools must still reject unknown arguments")
    }
    if case .failure = validator.check(name: "tagged", arguments: #"{"tags":{"anything":{"x":1}}}"#) { preconditionFailure("additionalProperties true rejected") }

    // Connector tools: the service validates its own schema; Halo only requires a JSON object.
    let connector = ToolValidator(definitions: Data(#"[{"type":"function","function":{"name":"notion__notion-create-pages","parameters":{"type":"object","properties":{"pages":{"type":"array"}},"required":["pages"]}}}]"#.utf8))!
    if case .failure(let problem) = connector.check(name: "notion__notion-create-pages", arguments: #"{"pages":[{"properties":{"title":"x"}}],"extra":1}"#) {
        preconditionFailure("connector call refused by Halo: \(problem.message)")
    }
    guard case .failure = connector.check(name: "notion__notion-create-pages", arguments: "[1]") else { preconditionFailure("non-object accepted") }
    guard case .failure = connector.check(name: "notion__made-up", arguments: "{}") else { preconditionFailure("unknown connector tool accepted") }
}

private struct FailingProvider: ReplyProvider {
    let partial: String
    let error: Error
    func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            if !partial.isEmpty { continuation.yield(partial) }
            continuation.finish(throwing: error)
        }
    }
}

/// A failed turn is said in the chat (and spoken), named, and logged; never only a status line.
@MainActor
func failuresAreToldAndLogged() async throws {
    let rejected = ToolValidator.RepeatedInvalidCalls(tool: "notion__notion-create-pages", problem: "pages[0].properties has unknown argument title")
    precondition(rejected.localizedDescription.hasPrefix("I couldn't run Notion's notion-create-pages"))
    precondition(rejected.localizedDescription.contains("never sent"))

    var spoken: [String] = []
    let conversation = Conversation(provider: FailingProvider(partial: "", error: rejected))
    conversation.onReply = { spoken.append($0) }
    conversation.send("make a page")
    try await Task.sleep(for: .milliseconds(250))
    precondition(conversation.messages.last?.text == rejected.localizedDescription, "the reason is Mercy's reply")
    precondition(spoken == [rejected.localizedDescription], "the reason is spoken")
    precondition(conversation.status.hasPrefix("Reply failed"))

    let other = Conversation(provider: FailingProvider(partial: "Working on it.", error: ProviderError.http(500)))
    other.send("x")
    try await Task.sleep(for: .milliseconds(250))
    precondition(other.messages.last?.text == "Working on it.\n\nSorry, I couldn't finish that. DeepSeek returned HTTP 500. Try again.")

    precondition(AgentLoop.toolFailure(#"{"ok":false,"error":"Notion said no"}"#) == "Notion said no")
    precondition(AgentLoop.toolFailure(#"{"ok":false,"denied":true,"error":"declined"}"#) == nil, "a declined approval is not a failure")
    precondition(AgentLoop.toolFailure(#"{"ok":true}"#) == nil)

    let log = FailureLog.shared.recent(5)
    precondition(log.contains { $0["kind"] as? String == "turn_failed" && ($0["detail"] as? String)?.contains("notion-create-pages") == true })
    precondition(FailureLog.shared.url.path.hasPrefix(NSTemporaryDirectory()) || FailureLog.shared.url.path.contains("/T/"), "checks never write the real log")
}

func connectorNamesAndKinds() {
    precondition(ConnectorManager.namespaced(app: "notion", tool: "notion-search") == "notion__notion-search")
    precondition(ConnectorManager.namespaced(app: "gmail", tool: "send message!") == "gmail__send_message_")
    precondition(ConnectorManager.namespaced(app: "x", tool: String(repeating: "a", count: 100)).count == 64)
    precondition(ConnectorManager.isConnectorTool("gmail__send_gmail_message") && ConnectorManager.isConnectorTool("notion__notion-search"))
    precondition(!ConnectorManager.isConnectorTool("list_browser_tabs") && !ConnectorManager.isConnectorTool("unknown__tool"))
    // The server's hint decides, but a write verb always wins and unknown means write.
    precondition(ConnectorManager.kind(name: "search_gmail_messages", readOnlyHint: nil) == .read)
    precondition(ConnectorManager.kind(name: "send_gmail_message", readOnlyHint: true) == .write)
    precondition(ConnectorManager.kind(name: "get_events", readOnlyHint: false) == .write)
    precondition(ConnectorManager.kind(name: "notion-fetch", readOnlyHint: true) == .read)
    precondition(ConnectorManager.kind(name: "do_thing", readOnlyHint: nil) == .write)
    precondition(ConnectorManager.kind(name: "list_issues", readOnlyHint: nil, destructiveHint: true) == .write)
    precondition(ConnectorManager.kind(name: "get_gmail_messages_content_batch", readOnlyHint: nil) == .read)
    let catalog = Set(ConnectorSpec.catalog.flatMap(\.apps))
    precondition(catalog == ["notion", "linear", "todoist", "stripe", "slack", "github", "gmail", "calendar", "drive", "sheets", "telegram", "discord"])
}

func vaultLabelsAndRestores() throws {
    let vault = PIIVault()
    vault.register(name: "Ada Lovelace")
    let labelled = vault.label(#"{"from":"ada@example.com","note":"Ada Lovelace called +1 415 555 0100 about ada@example.com","id":42}"#)
    let fields = object(labelled)
    precondition(fields["from"] as? String == "[EMAIL_1]" && fields["id"] as? Int == 42)
    precondition(fields["note"] as? String == "[PERSON_1] called [PHONE_1] about [EMAIL_1]")
    precondition(!labelled.contains("example.com") && !labelled.contains("555"))
    let restored = object(try vault.restore(#"{"to":"[EMAIL_1]","body":"Hi [PERSON_1]"}"#))
    precondition(restored["to"] as? String == "ada@example.com" && restored["body"] as? String == "Hi Ada Lovelace")
    var refused = false
    do { _ = try vault.restore(#"{"to":"[EMAIL_7]"}"#) } catch { refused = true }
    precondition(refused)
    precondition(vault.label("card 4111 1111 1111 1111 and order 1234567890123") == "card [CARD_1] and order 1234567890123")
    precondition(vault.label("already [EMAIL_1]") == "already [EMAIL_1]")
}

func stdioServerListsAndCalls() async throws {
    let client = MCPClient(transport: try MCPStdioTransport(command: "python3", arguments: [fakeServer], environment: [:]))
    try await client.initialize()
    let tools = try await client.listTools()
    precondition(tools.map(\.name) == ["echo", "send_note"], "paginated tools/list")
    precondition(tools[0].readOnlyHint == true && tools[1].readOnlyHint == nil)
    let echo = try await client.callTool("echo", arguments: Data(#"{"text":"hello"}"#.utf8))
    precondition(echo.text == "hello\n[image omitted]" && !echo.isError)
    let missing = try await client.callTool("nope", arguments: Data("{}".utf8))
    precondition(missing.isError)
    await client.close()
    var stopped = false
    do { _ = try await client.callTool("echo", arguments: Data(#"{"text":"x"}"#.utf8)) } catch { stopped = true }
    precondition(stopped)
}

func httpConnectorRefreshesAndReconnects() async throws {
    let port = 18000 + Int.random(in: 0..<2000)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", fakeServer, "--http", String(port)]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate() }
    try await Task.sleep(for: .milliseconds(600))

    let tokens = FakeTokens(["fake"])
    let spec = ConnectorSpec(id: "fake", name: "Fake", route: .hostedMCP(url: "http://127.0.0.1:\(port)/mcp"), auth: .discoveredOAuth,
                             aliases: ["fake"])
    let manager = ConnectorManager(tokens: tokens, connectors: [MCPConnector(spec: spec, tokens: tokens)])

    let empty = await manager.definitions(for: "open notes", reserved: [])
    let none = try JSONSerialization.jsonObject(with: empty) as! [Any]
    precondition(none.isEmpty, "unmentioned services add no tools")
    let added = await manager.definitions(for: "check fake for me", reserved: ["fake__send_note"])
    let rows = try JSONSerialization.jsonObject(with: added) as! [[String: Any]]
    let names = rows.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    precondition(names == ["fake__echo"], "reserved names are never shadowed: \(names)")
    // A follow-up that does not name the service keeps it while the
    // conversation does; once it scrolls out of context, it drops.
    let followUp = await manager.definitions(for: "write hey there in it", context: ["is fake connected?", "Yes, Fake is connected."], reserved: [])
    let followNames = (try JSONSerialization.jsonObject(with: followUp) as! [[String: Any]]).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    precondition(followNames.contains("fake__send_note"), "follow-up keeps the service named earlier")
    let unrelated = await manager.definitions(for: "write hey there in it", context: ["open safari", "Done."], reserved: [])
    let unrelatedRows = try JSONSerialization.jsonObject(with: unrelated) as! [Any]
    precondition(unrelatedRows.isEmpty, "services not mentioned recently stay out")
    let refreshes = await tokens.refreshes, kind = await manager.route("fake__echo")?.kind
    precondition(refreshes == 1, "401 triggers one refresh")
    precondition(kind == .read)

    let first = try await manager.execute(name: "fake__echo", arguments: Data(#"{"text":"one"}"#.utf8))
    // The server forgets the session after the first call; the next read reconnects once.
    let second = try await manager.execute(name: "fake__echo", arguments: Data(#"{"text":"two"}"#.utf8))
    precondition(first.hasPrefix("one") && second.hasPrefix("two"))

    var blocked = false
    do { _ = try await manager.execute(name: "fake__echo", arguments: Data(#"{"text":"post to https://www.linkedin.com/feed"}"#.utf8)) }
    catch { blocked = error.localizedDescription.contains("LinkedIn") }
    precondition(blocked, "LinkedIn is refused")
    await manager.shutdown()
}
