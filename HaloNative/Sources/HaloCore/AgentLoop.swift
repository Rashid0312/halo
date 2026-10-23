import Foundation

/// One tool call as the model asked for it.
public struct ToolRequest: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

/// A tool's result for the model. Approved screenshots travel as data URLs,
/// separate from the text, because each brain attaches images its own way.
public struct ToolOutput: Sendable {
    public var call: ToolRequest
    public var text: String
    public var imageURLs: [String]
    public init(call: ToolRequest, text: String, imageURLs: [String] = []) { self.call = call; self.text = text; self.imageURLs = imageURLs }
}

public enum RoundOutcome: Sendable {
    /// The visible answer is complete.
    case answered
    /// The model wants tools run; `text` is what it wrote first.
    case toolCalls(text: String, calls: [ToolRequest])
}

/// One brain's wire format. A backend starts a turn per request and keeps
/// that request's history in its own shape (e.g. ChatGPT's reasoning items).
public protocol ModelBackend: Sendable {
    /// Which brain and model answered, for recorded traces.
    var name: String { get }
    func startTurn(messages: [Message], tools: Data?) throws -> any ModelTurn
    /// Thrown when the request uses up its rounds.
    var actionLimitError: any Error { get }
    /// Thrown when the model calls a tool while none are available.
    var unavailableToolError: any Error { get }
}

public extension ModelBackend {
    var name: String { "unknown" }
}

public protocol ModelTurn: AnyObject {
    /// Streams one round's text through `emit` and returns what the model wants next.
    func round(emit: @escaping @Sendable (String) -> Void, status: @escaping @Sendable (String) async -> Void) async throws -> RoundOutcome
    func append(_ outputs: [ToolOutput])
}

/// The tool loop shared by every brain: rounds, tool execution, argument
/// validation, and screenshot attachment. Backends only speak their wire format.
public struct AgentLoop: ReplyProvider {
    public static let maxRounds = 12
    /// Earlier messages (both sides) that decide which connected services stay
    /// available to a follow-up: three exchanges back.
    public static let contextMessages = 6
    /// Rounds in a row whose calls were all rejected before the request stops.
    static let maxInvalidRounds = 3
    let backend: any ModelBackend
    let tools: (any MacToolExecutor)?
    let recorder: TraceRecorder
    public init(backend: any ModelBackend, tools: (any MacToolExecutor)?, recorder: TraceRecorder = .shared) {
        self.backend = backend; self.tools = tools; self.recorder = recorder
    }

    public func reply(to messages: [Message]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var draft: TraceDraft?
                do {
                    let prompt = messages.last(where: \.isUser)?.text ?? ""
                    let context = messages.dropLast().suffix(Self.contextMessages).map(\.text)
                    let definitions = try await tools?.definitions(for: prompt, context: Array(context))
                    let validator = definitions.flatMap(ToolValidator.init(definitions:))
                    draft = recorder.begin(brain: backend.name, instructions: DeepSeekProvider.assistantInstructions,
                                                       messages: messages, tools: definitions)
                    let turn = try backend.startTurn(messages: messages, tools: definitions)
                    let emit: @Sendable (String) -> Void = { [draft] in draft?.appendText($0); continuation.yield($0) }
                    let status: @Sendable (String) async -> Void = { [tools] in await tools?.reportStatus($0) }
                    var invalidRounds = 0
                    var lastRejection: (tool: String, problem: String)?
                    for _ in 0..<Self.maxRounds {
                        try Task.checkCancellation()
                        guard case .toolCalls(let text, let calls) = try await turn.round(emit: emit, status: status) else {
                            draft?.finish()
                            continuation.finish(); return
                        }
                        guard let tools else { throw backend.unavailableToolError }
                        if !text.isEmpty { continuation.yield("\n\n") }
                        var outputs: [ToolOutput] = []
                        var rejected: Set<String> = []
                        for var call in calls {
                            try Task.checkCancellation()
                            if let validator {
                                switch validator.check(name: call.name, arguments: call.arguments) {
                                case .success(let normalized): call.arguments = normalized
                                case .failure(let problem):
                                    rejected.insert(call.id)
                                    lastRejection = (call.name, problem.message)
                                    TimingLog.shared.mark("tool call rejected: \(call.name): \(problem.message)")
                                    FailureLog.shared.record(.callRejected, tool: call.name, detail: problem.message)
                                    outputs.append(ToolOutput(call: call, text: problem.toolResult))
                                    continue
                                }
                            }
                            let result = try await tools.execute(name: call.name, arguments: call.arguments)
                            try Task.checkCancellation()
                            if let failure = Self.toolFailure(result) { FailureLog.shared.record(.toolError, tool: call.name, detail: failure) }
                            if call.name == "inspect_screen", let attachment = Self.screenAttachment(result: result) {
                                outputs.append(ToolOutput(call: call, text: attachment.toolText, imageURLs: [attachment.imageURL]))
                            } else {
                                outputs.append(ToolOutput(call: call, text: result))
                            }
                        }
                        draft?.addStep(text: text, outputs: outputs, rejected: rejected)
                        invalidRounds = rejected.count == calls.count ? invalidRounds + 1 : 0
                        if invalidRounds >= Self.maxInvalidRounds {
                            throw ToolValidator.RepeatedInvalidCalls(tool: lastRejection?.tool ?? "", problem: lastRejection?.problem ?? "")
                        }
                        turn.append(outputs)
                    }
                    throw backend.actionLimitError
                } catch {
                    draft?.finish(error: Task.isCancelled ? CancellationError() : error)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The error a tool reported (`"ok": false`), unless the user declined it.
    public static func toolFailure(_ result: String) -> String? {
        guard result.contains("\"ok\":false") || result.contains("\"ok\": false"),
              let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              object["ok"] as? Bool == false, object["denied"] as? Bool != true else { return nil }
        return object["error"] as? String ?? "failed without a reason"
    }

    /// Splits an approved inspect_screen result into tool text and a JPEG data URL.
    public static func screenAttachment(result: String) -> (toolText: String, imageURL: String)? {
        guard var object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any],
              object["ok"] as? Bool == true, object["mime_type"] as? String == "image/jpeg",
              let base64 = object.removeValue(forKey: "image_base64") as? String,
              base64.count <= 6 * 1024 * 1024,
              let image = Data(base64Encoded: base64), !image.isEmpty, image.count <= 4 * 1024 * 1024,
              let text = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return (String(decoding: text, as: UTF8.self), "data:image/jpeg;base64," + base64)
    }
}

/// Checks a tool call against its definition before it runs: the tool exists,
/// required arguments are present, types and enums match, and no unknown
/// arguments are passed. Covers the JSON Schema subset Halo's tools use, plus
/// additionalProperties and anyOf/oneOf, which connector servers (Notion) use
/// for free-form maps and alternatives; unknown keywords are not checked.
/// Not a security boundary; approvals and the tools' own checks still apply.
public struct ToolValidator {
    public struct Problem: Error, Equatable {
        public let message: String
        /// Returned to the model in place of running the tool, so it can correct the call.
        public var toolResult: String {
            let object: [String: Any] = ["ok": false, "error": "Invalid tool call: \(message). Fix the call and try again."]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        }
    }
    /// Said to the user when every call in several rounds was refused: which
    /// tool and why, and that it never ran.
    public struct RepeatedInvalidCalls: LocalizedError {
        public var tool = ""
        public var problem = ""
        public init(tool: String = "", problem: String = "") { self.tool = tool; self.problem = problem }
        public var errorDescription: String? {
            guard !tool.isEmpty else { return "I kept building requests Halo couldn't run, so I stopped. Nothing was sent. Try rephrasing." }
            return "I couldn't run \(ToolValidator.displayName(tool)): Halo refused the request I built (\(problem)), so it was never sent. Try rephrasing, or tell me to try a different way."
        }
    }

    /// "Notion's notion-create-pages" for connector tools; Halo's own tools as named.
    public static func displayName(_ tool: String) -> String {
        guard let range = tool.range(of: ConnectorManager.separator) else { return tool }
        let app = String(tool[..<range.lowerBound])
        let name = ConnectorSpec.catalog.first { $0.apps.contains(app) }.map { $0.apps.count == 1 ? $0.name : app.capitalized } ?? app
        return "\(name)'s \(tool[range.upperBound...])"
    }

    private let schemas: [String: [String: Any]]
    public init?(definitions: Data) {
        guard let rows = try? JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] else { return nil }
        var schemas: [String: [String: Any]] = [:]
        for row in rows {
            guard let function = row["function"] as? [String: Any], let name = function["name"] as? String else { continue }
            schemas[name] = function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
        }
        self.schemas = schemas
    }

    /// The normalized argument JSON (`{}` for blank arguments) or the problem.
    /// Connector tools only need a JSON object here: the service checks its
    /// own schema and returns a precise error, so Halo never refuses a call
    /// its partial JSON Schema support misreads.
    public func check(name: String, arguments: String) -> Result<String, Problem> {
        guard let schema = schemas[name] else {
            return .failure(Problem(message: "there is no tool named \"\(name)\""))
        }
        let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "{}" : trimmed
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return .failure(Problem(message: "arguments for \(name) are not valid JSON"))
        }
        if ConnectorManager.isConnectorTool(name) {
            return value is [String: Any] ? .success(text) : .failure(Problem(message: "arguments for \(name) must be a JSON object"))
        }
        if let problem = Self.problem(value, schema: schema, path: name) { return .failure(Problem(message: problem)) }
        return .success(Self.withoutPlaceholders(value, schema: schema) ?? text)
    }

    /// Models fill optional arguments with placeholders ("", [], tab_id 0)
    /// that tools would take as real values. Optional arguments that are
    /// empty, or ID numbers that are 0, are dropped. Nil when nothing changed.
    static func withoutPlaceholders(_ value: Any, schema: [String: Any]) -> String? {
        guard var object = value as? [String: Any] else { return nil }
        let required = Set(schema["required"] as? [String] ?? [])
        let dropped = object.keys.filter { key in
            guard !required.contains(key), let item = object[key] else { return false }
            if let text = item as? String { return text.trimmingCharacters(in: .whitespaces).isEmpty }
            if let array = item as? [Any] { return array.isEmpty }
            if let number = item as? NSNumber, !isBool(number), key.hasSuffix("_id") { return number.intValue == 0 }
            return false
        }
        guard !dropped.isEmpty else { return nil }
        for key in dropped { object[key] = nil }
        return (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func problem(_ value: Any, schema: [String: Any], path: String) -> String? {
        if schema["type"] == nil, let options = (schema["anyOf"] ?? schema["oneOf"]) as? [[String: Any]], !options.isEmpty {
            let problems = options.map { problem(value, schema: $0, path: path) }
            return problems.contains { $0 == nil } ? nil : problems.compactMap { $0 }.first
        }
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { equal($0, value) }) {
            return "\(path) must be one of \(allowed.map { "\($0)" }.joined(separator: ", "))"
        }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return "\(path) must be an object" }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            for key in (schema["required"] as? [String] ?? []) where object[key] == nil || object[key] is NSNull {
                return "\(path) is missing required \(key)"
            }
            for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                // A map with open keys (additionalProperties true or a schema)
                // accepts names it does not list; without it, unlisted names are errors.
                guard let property = properties[key] ?? schema["additionalProperties"] as? [String: Any]
                        ?? ((schema["additionalProperties"] as? Bool) == true ? [:] : nil) else {
                    return "\(path) has unknown argument \(key)"
                }
                if item is NSNull { continue }
                if let problem = problem(item, schema: property, path: "\(path).\(key)") { return problem }
            }
        case "array":
            guard let array = value as? [Any] else { return "\(path) must be an array" }
            if let items = schema["items"] as? [String: Any] {
                for (index, item) in array.enumerated() {
                    if let problem = problem(item, schema: items, path: "\(path)[\(index)]") { return problem }
                }
            }
        case "string": if !(value is String) { return "\(path) must be a string" }
        case "boolean": if !isBool(value) { return "\(path) must be true or false" }
        case "integer":
            guard let number = value as? NSNumber, !isBool(value), number.doubleValue.rounded() == number.doubleValue else {
                return "\(path) must be a whole number"
            }
        case "number": if !(value is NSNumber) || isBool(value) { return "\(path) must be a number" }
        case "null": if !(value is NSNull) { return "\(path) must be null" }
        default: break
        }
        return nil
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? NSNumber, let b = b as? NSNumber { return a == b && isBool(a) == isBool(b) }
        return false
    }
}
