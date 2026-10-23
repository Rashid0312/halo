import Foundation
import Darwin

/// A connector backed by an MCP server: hosted by the service, or run on this
/// Mac over stdio or 127.0.0.1. Connects on first use and reconnects once if
/// the session or process was lost.
public actor MCPConnector: Connector {
    public nonisolated let spec: ConnectorSpec
    private let tokens: any ConnectorTokenSource
    private var client: MCPClient?
    private var server: Process?
    private var cached: [MCPClient.Tool]?

    public init(spec: ConnectorSpec, tokens: any ConnectorTokenSource) {
        self.spec = spec; self.tokens = tokens
    }

    public func tools() async throws -> [ConnectorTool] {
        let tools: [MCPClient.Tool]
        if let cached { tools = cached } else {
            tools = try await retrying { try await $0.listTools() }
            cached = tools
        }
        return tools.map {
            ConnectorTool(app: spec.app(for: $0.name), name: $0.name, description: $0.description, schema: $0.inputSchema,
                          kind: ConnectorManager.kind(name: $0.name, readOnlyHint: $0.readOnlyHint, destructiveHint: $0.destructiveHint))
        }
    }

    public func call(_ tool: String, arguments: Data) async throws -> String {
        let result = try await retrying { try await $0.callTool(tool, arguments: arguments) }
        if result.isError { throw MCPError(result.text.isEmpty ? "\(spec.name) reported an error." : result.text) }
        return result.text
    }

    public func shutdown() async {
        await client?.close()
        client = nil; cached = nil
        if let server, server.isRunning { server.terminate() }
        server = nil
    }

    /// Reconnects and sends again only when the request cannot have run: the
    /// server dropped the session, or the local process had already stopped.
    /// Anything else is reported, so a send or payment is never repeated.
    private func retrying<T: Sendable>(_ body: (MCPClient) async throws -> T) async throws -> T {
        do { return try await body(try await connected()) }
        catch let error as MCPError where error.kind == .sessionExpired || error.kind == .notRunning {
            await shutdown()
            return try await body(try await connected())
        } catch let error as MCPError where error.kind == .unauthorized {
            throw MCPError("\(spec.name) rejected Halo's sign-in. Reconnect \(spec.name) in Halo Settings.")
        } catch {
            // A network failure may have broken the session: rebuild it on the
            // next call, without resending this one.
            if !(error is MCPError), !(error is CancellationError) { await shutdown() }
            throw error
        }
    }

    private func connected() async throws -> MCPClient {
        if let client { return client }
        let id = spec.id, tokens = tokens
        guard let token = try await tokens.token(for: id, forceRefresh: false) else {
            throw MCPError("\(spec.name) is not connected. Connect it in Halo Settings.")
        }
        let next: MCPClient
        switch spec.route {
        case .hostedMCP(let url):
            guard let endpoint = URL(string: url) else { throw MCPError("Bad \(spec.name) address.") }
            next = MCPClient(transport: MCPHTTPTransport(endpoint: endpoint) { force in try await tokens.token(for: id, forceRefresh: force) })
        case .stdioMCP(let command, let arguments, let variable):
            next = MCPClient(transport: try MCPStdioTransport(command: command, arguments: arguments, environment: [variable: token]))
        case .localHTTPMCP(let command, let arguments, let environment):
            next = try await launchLocal(command: command, arguments: arguments, environment: environment)
        case .directAPI:
            throw MCPError("\(spec.name) is not an MCP connector.")
        }
        try await next.initialize()
        client = next
        return next
    }

    /// Starts the server on a free 127.0.0.1 port and waits until it answers.
    /// The token never reaches the process; it is sent as a bearer per request.
    private func launchLocal(command: String, arguments: [String], environment: [String: String]) async throws -> MCPClient {
        guard let clientID = await tokens.setting("client_id", for: spec.id) else {
            throw MCPError("Add \(spec.name)'s OAuth client in Halo Settings first.")
        }
        let port = try Self.freePort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = ["HOME": NSHomeDirectory(), "PATH": MCPStdioTransport.searchPath, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
                               "WORKSPACE_MCP_PORT": String(port), "GOOGLE_OAUTH_CLIENT_ID": clientID]
            .merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        ConnectorProcesses.add(process)
        server = process
        let id = spec.id, tokens = tokens
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        // The first launch downloads the server with uvx, which can take a while.
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            guard process.isRunning else { throw MCPError("\(spec.name)'s local server stopped while starting. Is uv installed?") }
            var probe = URLRequest(url: endpoint)
            probe.timeoutInterval = 2
            if (try? await URLSession.shared.data(for: probe)) != nil { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        return MCPClient(transport: MCPHTTPTransport(endpoint: endpoint) { force in try await tokens.token(for: id, forceRefresh: force) })
    }

    static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPError("Could not find a free local port.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { throw MCPError("Could not find a free local port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
