import Foundation

/// The client half of the Model Context Protocol, limited to what Halo uses:
/// initialize, list tools, call a tool. No sampling, roots, or elicitation.
public actor MCPClient {
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        /// JSON Schema object for the arguments, as JSON.
        public let inputSchema: Data
        public let readOnlyHint: Bool?
        public let destructiveHint: Bool?
    }

    public struct CallResult: Sendable {
        public let text: String
        public let isError: Bool
    }

    public static let protocolVersion = "2025-06-18"
    private let transport: any MCPTransport
    private var nextID = 1
    private var initialized = false
    public private(set) var serverName = ""

    public init(transport: any MCPTransport) { self.transport = transport }

    public func initialize() async throws {
        let result = try await request("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "Halo", "version": "1.0"],
        ])
        if let version = result["protocolVersion"] as? String, let http = transport as? MCPHTTPTransport { http.setProtocolVersion(version) }
        serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String ?? ""
        _ = try await transport.send(Self.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]), id: nil)
        initialized = true
    }

    public func listTools() async throws -> [Tool] {
        if !initialized { try await initialize() }
        var tools: [Tool] = [], cursor: String?
        repeat {
            let result = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            for row in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = row["name"] as? String else { continue }
                let schema = row["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:] as [String: Any]]
                let annotations = row["annotations"] as? [String: Any]
                tools.append(Tool(name: name, description: row["description"] as? String ?? "",
                                  inputSchema: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8),
                                  readOnlyHint: annotations?["readOnlyHint"] as? Bool,
                                  destructiveHint: annotations?["destructiveHint"] as? Bool))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1000
        return tools
    }

    /// `arguments` is a JSON object.
    public func callTool(_ name: String, arguments: Data) async throws -> CallResult {
        if !initialized { try await initialize() }
        let arguments = (try? JSONSerialization.jsonObject(with: arguments) as? [String: Any]) ?? [:]
        let result = try await request("tools/call", ["name": name, "arguments": arguments])
        return CallResult(text: Self.text(of: result), isError: result["isError"] as? Bool ?? false)
    }

    public func close() async { await transport.close() }

    /// Flattens a tools/call result: text parts in order; structured content
    /// when there is no text; other media named rather than included.
    static func text(of result: [String: Any]) -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text": parts.append(item["text"] as? String ?? "")
            case "resource":
                let resource = item["resource"] as? [String: Any] ?? [:]
                parts.append(resource["text"] as? String ?? "[resource \(resource["uri"] as? String ?? "")]")
            case "resource_link": parts.append("[link \(item["name"] as? String ?? "") \(item["uri"] as? String ?? "")]")
            case let other?: parts.append("[\(other) omitted]")
            case nil: break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return parts.joined(separator: "\n")
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let message = try Self.encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        guard let data = try await transport.send(message, id: id),
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPError("The connector sent an unreadable answer to \(method).")
        }
        if let error = response["error"] as? [String: Any] {
            throw MCPError("The connector refused \(method): \(error["message"] as? String ?? "unknown error")")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
