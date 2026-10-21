import Foundation

public protocol MacToolExecutor: Sendable {
    func definitions() async throws -> Data
    /// The tool list for one request; may leave out tools that don't fit it.
    func definitions(for prompt: String) async throws -> Data
    func execute(name: String, arguments: String) async throws -> String
    /// Shows a provider status line (e.g. a retry) in the activity list.
    func reportStatus(_ text: String) async
}

public extension MacToolExecutor {
    func reportStatus(_ text: String) async {}
    func definitions(for prompt: String) async throws -> Data { try await definitions() }
}

/// Which tools a request needs. Browser requests get no Mac app-discovery
/// tools: models call them first even when told not to, at ~3 s a step.
public enum ToolScope {
    public static let appDiscoveryTools: Set<String> = ["list_apps", "running_apps", "open_app", "inspect_ui"]
    private static let browserWords: Set<String> = [
        "chrome", "browser", "tab", "tabs", "website", "websites", "site", "webpage", "url", "link",
        "youtube", "netflix", "gmail", "google", "reddit", "amazon", "twitter", "facebook", "instagram",
        "linkedin", "github", "wikipedia", "spotify", "twitch", "hulu", "vimeo", "disney",
    ]

    public static func isBrowserRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") || lower.contains("web page") { return true }
        if lower.range(of: #"\b[a-z0-9-]+\.(com|net|org|io|co|tv|app|dev|ai|edu|gov|me|uk|ca|de)\b"#, options: .regularExpression) != nil { return true }
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { browserWords.contains(String($0)) }
    }

    /// `definitions` with the app-discovery tools removed for browser requests.
    public static func definitions(_ definitions: Data, for prompt: String) -> Data {
        guard isBrowserRequest(prompt),
              let rows = try? JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] else { return definitions }
        let kept = rows.filter { row in
            guard let name = (row["function"] as? [String: Any])?["name"] as? String else { return true }
            return !appDiscoveryTools.contains(name)
        }
        return (try? JSONSerialization.data(withJSONObject: kept)) ?? definitions
    }
}

public struct ToolFragment: Decodable, Sendable {
    public var index: Int
    public var id: String?
    public var function: Function?
    public struct Function: Decodable, Sendable {
        public var name: String?
        public var arguments: String?
    }
}

public struct ToolCall: Sendable {
    public var id = ""
    public var name = ""
    public var arguments = ""
    public init() {}
    public mutating func append(_ fragment: ToolFragment) {
        if let id = fragment.id { self.id = id }
        name += fragment.function?.name ?? ""
        arguments += fragment.function?.arguments ?? ""
    }
}
