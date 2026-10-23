import Foundation
import SwiftUI
import HaloCore

/// --check-connectors-offline: MacTools with a fake local MCP server standing in
/// for Notion. --check-connector <id>: a real connected service, read-only.
@MainActor
enum ConnectorChecks {
    typealias Failure = NativeChecks.Failure
    private static let fakeServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Fixtures/FakeMCPServer.py").standardizedFileURL.path

    private struct FixedTokens: ConnectorTokenSource {
        func token(for connector: String, forceRefresh: Bool) async throws -> String? { connector == "notion" ? "unused" : nil }
        func setting(_ name: String, for connector: String) async -> String? { nil }
    }

    static func offline() async throws {
        let spec = ConnectorSpec(id: "notion", name: "Notion", route: .stdioMCP(command: "python3", arguments: [fakeServer], tokenVariable: "FAKE_TOKEN"),
                                 auth: .discoveredOAuth, aliases: ["notion"])
        let tokens = FixedTokens()
        let manager = ConnectorManager(tokens: tokens, connectors: [MCPConnector(spec: spec, tokens: tokens)])
        let tools = MacTools(catalog: AppCatalog(), connectors: manager)
        defer { Task { await manager.shutdown() } }
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:] }
        func names(_ data: Data) -> [String] {
            ((try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        }

        // Requests that name no connected app get exactly the built-in list.
        for prompt in ["open notes", "list my browser tabs", "arrange the Safari window left"] {
            let merged = try await tools.definitions(for: prompt)
            // ToolScope re-serializes filtered lists, so compare with sorted keys.
            func normal(_ data: Data) throws -> Data {
                try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: .sortedKeys)
            }
            guard try normal(merged) == normal(ToolScope.definitions(MacTools.toolDefinitions, for: prompt)) else {
                throw Failure("Tool list changed for '\(prompt)'")
            }
        }
        let withNotion = names(try await tools.definitions(for: "search notion for the roadmap"))
        let builtIn = names(MacTools.toolDefinitions)
        guard Array(withNotion.prefix(builtIn.count)) == builtIn, Array(withNotion.dropFirst(builtIn.count)) == ["notion__echo", "notion__send_note"] else {
            throw Failure("Connector tools were not appended after the built-in tools: \(withNotion)")
        }
        print("PASS: built-in tools are unchanged; connector tools are appended, namespaced, only when the request names the app")

        let echo = object(try await tools.execute(name: "notion__echo", arguments: #"{"text":"hello"}"#))
        guard echo["ok"] as? Bool == true, (echo["result"] as? String)?.hasPrefix("hello") == true, tools.approval == nil,
              (echo["note"] as? String)?.contains("untrusted") == true else { throw Failure("Read tool failed: \(echo)") }

        let send = #"{"to":"ada@example.com","body":"hi"}"#
        let declined = Task { try await tools.execute(name: "notion__send_note", arguments: send) }
        let first = try await waitForApproval(tools)
        guard first.title.hasPrefix("Notion:"), first.preview.contains("ada@example.com") else { throw Failure("Write approval preview is wrong") }
        tools.resolve(id: first.id, allow: false)
        guard object(try await declined.value)["denied"] as? Bool == true else { throw Failure("Declined write was not reported") }
        let accepted = Task { try await tools.execute(name: "notion__send_note", arguments: send) }
        tools.resolve(id: try await waitForApproval(tools).id, allow: true)
        let sent = object(try await accepted.value)
        // The fake server counts sends: 1 proves the declined call never reached it.
        guard sent["result"] as? String == "sent to ada@example.com (1)" else { throw Failure("Approved write result: \(sent)") }
        print("PASS: connector reads run without approval; writes wait for approval, and a declined write never reaches the service")

        tools.privacyScrub = true
        let labelled = object(try await tools.execute(name: "notion__echo", arguments: #"{"text":"reach ada@example.com"}"#))
        guard labelled["result"] as? String == "reach [EMAIL_1]\n[image omitted]" else { throw Failure("Result was not labelled: \(labelled)") }
        let restoring = Task { try await tools.execute(name: "notion__send_note", arguments: #"{"to":"[EMAIL_1]","body":"hi"}"#) }
        let preview = try await waitForApproval(tools)
        guard preview.preview.contains("ada@example.com"), !preview.preview.contains("[EMAIL_1]") else { throw Failure("Approval did not show the real value") }
        tools.resolve(id: preview.id, allow: true)
        let restored = object(try await restoring.value)
        guard restored["result"] as? String == "sent to [EMAIL_1] (2)" else { throw Failure("Real value was not used or result not relabelled: \(restored)") }
        let guessed = object(try await tools.execute(name: "notion__send_note", arguments: #"{"to":"[EMAIL_9]","body":"hi"}"#))
        guard guessed["ok"] as? Bool == false, tools.approval == nil else { throw Failure("An unknown label was not refused") }
        tools.privacyScrub = false
        print("PASS: privacy scrub labels results for the model, restores real values only for the call and its approval, and refuses unknown labels")
    }

    /// macOS delivers halo://oauth/callback to this app and it reaches the
    /// sign-in waiting on that state; a callback with another state does not.
    static func callback() async throws {
        let state = UUID().uuidString, other = UUID().uuidString
        let waiting = Task { try await OAuthCallbackRouter.shared.wait(state: state, service: "Check") }
        try await Task.sleep(for: .milliseconds(200))
        for value in [other, state] {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "\(OAuthCallbackRouter.redirect)?state=\(value)&code=check-only"]
            try open.run(); open.waitUntilExit()
            try await Task.sleep(for: .milliseconds(300))
        }
        let timeout = Task { try await Task.sleep(for: .seconds(15)); waiting.cancel() }
        let url = try await waiting.value
        timeout.cancel()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state, items.first(where: { $0.name == "code" })?.value == "check-only" else {
            throw Failure("The wrong callback reached the sign-in")
        }
        print("PASS: halo://oauth/callback is registered, reaches the running app, and is matched to its sign-in by state")
    }

    /// Renders the Connect card in each state to PNGs in `folder`, for review.
    static func renderCards(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let accounts = ConnectorAccounts(manager: ConnectorManager(tokens: ConnectorTokenStore.shared))
        let states: [(String, ConnectorAccounts.Phase)] = [("idle", .idle), ("waiting", .waitingForBrowser), ("connected", .connected),
                                                            ("failed", .failed("Notion sign-in was declined or cancelled."))]
        for id in ["notion", "google"] {
            guard let spec = ConnectorSpec.spec(id) else { continue }
            for (name, phase) in states where id == "notion" || name == "idle" {
                accounts.preview(phase, for: spec)
                let renderer = ImageRenderer(content: ConnectCard(spec: spec, accounts: accounts, close: {}).background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw Failure("Could not render \(id) \(name)") }
                try png.write(to: folder.appendingPathComponent("\(id)-\(name).png"))
            }
        }
        print("PASS: Connect card rendered for each state in \(folder.path)")
    }

    /// Lists a real connected service's tools and runs one read-only tool.
    static func live(_ id: String, tool requested: String?, arguments: String) async throws {
        guard let spec = ConnectorSpec.spec(id) else { throw Failure("Unknown connector \(id)") }
        let manager = ConnectorManager(tokens: ConnectorTokenStore.shared)
        defer { Task { await manager.shutdown() } }
        let tools = try await manager.tools(of: id)
        print("PASS: \(spec.name) listed \(tools.count) tools (\(tools.filter { $0.kind == .read }.count) read, \(tools.filter { $0.kind == .write }.count) write)")
        let definitions = await manager.definitions(for: spec.aliases[0], reserved: MacTools.toolNames)
        let added = try JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] ?? []
        let names = added.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        guard let name = requested.map({ ConnectorManager.namespaced(app: spec.app(for: $0), tool: $0) }) ?? names.first(where: { name in
            tools.contains { ConnectorManager.namespaced(app: $0.app, tool: $0.name) == name && $0.kind == .read }
        }) else { throw Failure("No read-only tool to call") }
        guard let route = await manager.route(name), route.kind == .read else { throw Failure("\(name) is not a read-only tool; live checks never write") }
        let result = try await manager.execute(name: name, arguments: Data(arguments.utf8))
        print("PASS: \(name) returned \(result.count) characters; contents not printed")
    }

    private static func waitForApproval(_ tools: MacTools) async throws -> MacTools.Approval {
        for _ in 0..<500 {
            if let approval = tools.approval { return approval }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Approval did not appear")
    }
}
