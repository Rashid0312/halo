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

/// Which tools a request needs. Browser requests get no Mac app-discovery or
/// Mac UI-control tools: models call them first even when told not to, at
/// ~3 s a step, and every definition is re-read on every step. A request that
/// also mentions Mac windows, menus, or dialogs keeps every tool.
public enum ToolScope {
    public static let appDiscoveryTools: Set<String> = ["list_apps", "running_apps", "open_app", "inspect_ui"]
    public static let macControlTools: Set<String> = [
        "ui_action", "type_text", "keypress", "scroll", "focus_app", "list_windows", "list_menus",
        "click_menu_item", "find_dialog", "click_dialog_button", "window_layout", "screen_info",
    ]
    private static let browserWords: Set<String> = [
        "chrome", "browser", "tab", "tabs", "website", "websites", "site", "webpage", "url", "link",
        "youtube", "netflix", "gmail", "google", "reddit", "amazon", "twitter", "facebook", "instagram",
        "linkedin", "github", "wikipedia", "spotify", "twitch", "hulu", "vimeo", "disney",
    ]
    private static let macWords: Set<String> = [
        "window", "windows", "arrange", "layout", "menu", "menus", "dialog", "finder", "desktop", "display", "monitor",
    ]

    private static func words(_ prompt: String) -> [String] {
        prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    public static func isBrowserRequest(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") || lower.contains("web page") { return true }
        if lower.range(of: #"\b[a-z0-9-]+\.(com|net|org|io|co|tv|app|dev|ai|edu|gov|me|uk|ca|de)\b"#, options: .regularExpression) != nil { return true }
        return words(prompt).contains { browserWords.contains($0) }
    }

    /// Whether a request also needs Mac app or window control.
    public static func mentionsMacControl(_ prompt: String) -> Bool {
        words(prompt).contains { macWords.contains($0) }
    }

    /// `definitions` with the Mac app-discovery and UI-control tools removed for browser-only requests.
    public static func definitions(_ definitions: Data, for prompt: String) -> Data {
        guard isBrowserRequest(prompt), !mentionsMacControl(prompt),
              let rows = try? JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] else { return definitions }
        let kept = rows.filter { row in
            guard let name = (row["function"] as? [String: Any])?["name"] as? String else { return true }
            return !appDiscoveryTools.contains(name) && !macControlTools.contains(name)
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
