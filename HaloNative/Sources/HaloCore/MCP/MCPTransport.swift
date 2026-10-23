import Foundation
import Darwin

public struct MCPError: LocalizedError, Sendable {
    public enum Kind: Sendable { case failed, unauthorized, sessionExpired, notRunning }
    public let kind: Kind
    public let errorDescription: String?
    public init(_ text: String, kind: Kind = .failed) { errorDescription = text; self.kind = kind }
    /// The server forgot the session (HTTP 404 with a session id); the
    /// request was not run, so reconnecting and sending again is safe.
    public static let sessionExpired = MCPError("The connector session expired.", kind: .sessionExpired)
    public static let unauthorized = MCPError("The connector rejected Halo's sign-in.", kind: .unauthorized)
}

/// Carries JSON-RPC messages to one MCP server. Requests (with an `id`)
/// return the matching response object; notifications return nil.
public protocol MCPTransport: Sendable {
    func send(_ message: Data, id: Int?) async throws -> Data?
    func close() async
}

/// Local connector servers Halo started, so quitting Halo stops them too
/// (applicationWillTerminate cannot wait for the connector actors).
public enum ConnectorProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var running: [Process] = []

    static func add(_ process: Process) {
        lock.withLock { running = running.filter(\.isRunning) + [process] }
    }

    public static func terminateAll() {
        let processes = lock.withLock { () -> [Process] in defer { running = [] }; return running }
        for process in processes where process.isRunning { process.terminate() }
    }
}

/// A local server launched as a child process, speaking newline-delimited
/// JSON-RPC over stdin/stdout. Halo's own credentials are never inherited:
/// the environment is built from scratch plus what the connector names.
public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    public static let searchPath = ["~/.local/bin", "~/go/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .map { ($0 as NSString).expandingTildeInPath }.joined(separator: ":")

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var buffer = Data()
    private var errorTail = Data()
    private var closed = false
    private let timeout: Duration

    public init(command: String, arguments: [String], environment: [String: String], timeout: Duration = .seconds(60)) throws {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        process.environment = ["HOME": NSHomeDirectory(), "PATH": Self.searchPath, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
            .merging(environment) { _, new in new }
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receiveError(handle.availableData) }
        process.terminationHandler = { [weak self] _ in self?.fail(MCPError("The connector process stopped.")) }
        try process.run()
        ConnectorProcesses.add(process)
    }

    deinit { if process.isRunning { process.terminate() } }

    public func send(_ message: Data, id: Int?) async throws -> Data? {
        guard let id else { try write(message); return nil }
        let timeout = timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                lock.lock()
                if closed { lock.unlock(); continuation.resume(throwing: failure("The connector is not running.", kind: .notRunning)); return }
                pending[id] = continuation
                lock.unlock()
                do { try write(message) } catch { resume(id, with: .failure(error)) }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resume(id, with: .failure(MCPError("The connector did not answer in time.")))
                }
            }
        } onCancel: { [weak self] in self?.resume(id, with: .failure(CancellationError())) }
    }

    public func close() async {
        lock.withLock { closed = true }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        fail(MCPError("The connector was closed."))
    }

    private func write(_ message: Data) throws {
        var line = message
        line.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<end])
            buffer.removeSubrange(buffer.startIndex...end)
        }
        // A server that never ends a line cannot grow memory without bound.
        if buffer.count > 16 * 1024 * 1024 { buffer.removeAll() }
        lock.unlock()
        for line in lines where !line.isEmpty { handle(Data(line)) }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let method = object["method"] as? String, let id = object["id"] {
            // Server-to-client requests: answer ping, decline everything else
            // (Halo offers no sampling, roots, or elicitation).
            let reply: [String: Any] = method == "ping"
                ? ["jsonrpc": "2.0", "id": id, "result": [:]]
                : ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by Halo"]]
            if let data = try? JSONSerialization.data(withJSONObject: reply) { try? write(data) }
            return
        }
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }
        resume(id, with: .success(line))
    }

    private func receiveError(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        errorTail.append(data)
        if errorTail.count > 4096 { errorTail = errorTail.suffix(4096) }
    }

    private func resume(_ id: Int, with result: Result<Data, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: id)
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func fail(_ error: MCPError) {
        lock.lock()
        closed = true
        let waiting = pending.values
        pending.removeAll()
        lock.unlock()
        let failure = failure(error.errorDescription ?? "")
        waiting.forEach { $0.resume(throwing: failure) }
    }

    /// Adds the last line the server printed to stderr; servers explain startup failures there.
    private func failure(_ text: String, kind: MCPError.Kind = .failed) -> MCPError {
        lock.lock(); let tail = String(decoding: errorTail, as: UTF8.self); lock.unlock()
        let last = tail.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return MCPError(last.isEmpty ? text : "\(text) \(Scrubber.scrub(String(last.prefix(300))))", kind: kind)
    }
}

/// Streamable HTTP: one POST per message; the reply is JSON or a short SSE
/// stream. Keeps the server's session id and sends a fresh bearer token each
/// time, refreshing once on 401.
public final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    public typealias TokenSource = @Sendable (_ forceRefresh: Bool) async throws -> String?
    private let endpoint: URL
    private let token: TokenSource
    private let session: URLSession
    private let lock = NSLock()
    private var sessionID: String?
    private var protocolVersion: String?

    public init(endpoint: URL, token: @escaping TokenSource) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
    }

    public func setProtocolVersion(_ version: String) { lock.withLock { protocolVersion = version } }

    public func send(_ message: Data, id: Int?) async throws -> Data? {
        do { return try await post(message, id: id, forceRefresh: false) }
        catch let error as MCPError where error.kind == .unauthorized {
            return try await post(message, id: id, forceRefresh: true)
        }
    }

    private func post(_ message: Data, id: Int?, forceRefresh: Bool) async throws -> Data? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (sessionID, version) = lock.withLock { (self.sessionID, protocolVersion) }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let bearer = try await token(forceRefresh) { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError("The connector sent no HTTP response.") }
        if let next = http.value(forHTTPHeaderField: "Mcp-Session-Id") { lock.withLock { self.sessionID = next } }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MCPError.unauthorized
        case 404 where sessionID != nil:
            lock.withLock { self.sessionID = nil }
            throw MCPError.sessionExpired
        default: throw MCPError("The connector answered HTTP \(http.statusCode).")
        }
        guard let id else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            var event = SSEEventReader()
            for try await line in bytes.lines {
                guard let data = event.feed(line) else { continue }
                if Self.responseID(data) == id { return data }
            }
            if let data = event.finish(), Self.responseID(data) == id { return data }
            throw MCPError("The connector closed its stream without answering.")
        }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > 16 * 1024 * 1024 { throw MCPError("The connector's answer was too large.") }
        }
        if let rows = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
           let row = rows.first(where: { ($0["id"] as? NSNumber)?.intValue == id }) {
            return try JSONSerialization.data(withJSONObject: row)
        }
        return body
    }

    static func responseID(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["method"] == nil else { return nil }
        return (object["id"] as? NSNumber)?.intValue
    }

    public func close() async {
        let sessionID = lock.withLock { () -> String? in defer { self.sessionID = nil }; return self.sessionID }
        guard let sessionID else { return }
        // Tells the server to drop the session; failure is harmless.
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        if let bearer = try? await token(false) { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        _ = try? await session.data(for: request)
    }
}

/// Joins SSE `data:` lines into one payload per event. `URLSession.AsyncBytes.lines`
/// drops the blank lines that end events, so an event is complete as soon as
/// its data so far parses as JSON; a blank line (when seen) also ends it.
public struct SSEEventReader: Sendable {
    private var lines: [String] = []
    public init() {}

    public mutating func feed(_ line: String) -> Data? {
        if line.isEmpty { return finish() }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        lines.append(value)
        let data = Data(lines.joined(separator: "\n").utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        lines = []
        return data
    }

    public mutating func finish() -> Data? {
        guard !lines.isEmpty else { return nil }
        defer { lines = [] }
        return Data(lines.joined(separator: "\n").utf8)
    }
}
