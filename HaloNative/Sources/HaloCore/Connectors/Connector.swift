import Foundation

/// Whether a connector tool only reads, or changes something (send, post,
/// create, pay, delete…). Writes always wait for the user's approval.
public enum ConnectorToolKind: String, Sendable { case read, write }

public struct ConnectorTool: Sendable {
    /// The app namespace the model sees, e.g. "gmail" in gmail__send.
    public let app: String
    /// The tool's own name on its server or API.
    public let name: String
    public let description: String
    /// JSON Schema object for the arguments, as JSON.
    public let schema: Data
    public let kind: ConnectorToolKind

    public init(app: String, name: String, description: String, schema: Data, kind: ConnectorToolKind) {
        self.app = app; self.name = name; self.description = description; self.schema = schema; self.kind = kind
    }
}

/// One connected service: an MCP server (hosted or local) or a direct API.
public protocol Connector: Sendable {
    var spec: ConnectorSpec { get }
    func tools() async throws -> [ConnectorTool]
    /// Runs one tool with real (already restored) argument values; returns its text result.
    func call(_ tool: String, arguments: Data) async throws -> String
    func shutdown() async
}

/// Where a token comes from. Implemented by the app over its Credentials store.
public protocol ConnectorTokenSource: Sendable {
    /// The bearer token or API key for a connector, refreshed when `forceRefresh`
    /// or near expiry. Nil when the user has not connected it.
    func token(for connector: String, forceRefresh: Bool) async throws -> String?
    /// Non-secret settings a connector needs at launch (e.g. an OAuth client id).
    func setting(_ name: String, for connector: String) async -> String?
}

/// How Halo reaches one service. All routes are free: the service's own
/// hosted MCP server, an open-source server run on this Mac, or the service's
/// REST API with the user's own token. See docs/CONNECTORS.md.
public struct ConnectorSpec: Sendable {
    public enum Route: Sendable {
        /// The service hosts the MCP server; Halo signs in with OAuth.
        case hostedMCP(url: String)
        /// A local server over stdin/stdout; the token is passed in `tokenVariable`.
        case stdioMCP(command: String, arguments: [String], tokenVariable: String)
        /// A local server on 127.0.0.1 that takes the token as a bearer per request.
        case localHTTPMCP(command: String, arguments: [String], environment: [String: String])
        /// The service's REST API, called by Halo directly.
        case directAPI
    }

    public enum Auth: Sendable {
        /// OAuth found from the server's metadata, with dynamic client registration.
        case discoveredOAuth
        /// OAuth with a client the developer registered (id and secret in Settings).
        case configuredOAuth(authorize: String, token: String, scopes: [String], extra: [String: String])
        /// A personal or bot token pasted in Settings.
        case token(label: String, help: String)
    }

    public let id: String
    public let name: String
    public let route: Route
    public let auth: Auth
    /// Namespaces this connector's tools use; most connectors have one.
    public let apps: [String]
    /// Words in a request that bring this connector's tools into the tool list.
    public let aliases: [String]
    /// For connectors serving several apps: which app a tool belongs to.
    let appForTool: (@Sendable (String) -> String)?

    public init(id: String, name: String, route: Route, auth: Auth, apps: [String]? = nil, aliases: [String],
         appForTool: (@Sendable (String) -> String)? = nil) {
        self.id = id; self.name = name; self.route = route; self.auth = auth
        self.apps = apps ?? [id]; self.aliases = aliases; self.appForTool = appForTool
    }

    public func app(for tool: String) -> String { appForTool?(tool) ?? apps[0] }

    /// Pinned versions: a new server release can change tool names and arguments.
    public static let githubServerVersion = "v2.0.3"
    public static let workspaceServerVersion = "2.1.2"

    public static let catalog: [ConnectorSpec] = [
        ConnectorSpec(id: "notion", name: "Notion", route: .hostedMCP(url: "https://mcp.notion.com/mcp"), auth: .discoveredOAuth,
                      aliases: ["notion"]),
        ConnectorSpec(id: "linear", name: "Linear", route: .hostedMCP(url: "https://mcp.linear.app/mcp"), auth: .discoveredOAuth,
                      aliases: ["linear", "issue", "issues", "ticket", "tickets"]),
        ConnectorSpec(id: "todoist", name: "Todoist", route: .hostedMCP(url: "https://ai.todoist.net/mcp"), auth: .discoveredOAuth,
                      aliases: ["todoist", "todo", "todos", "task", "tasks", "to-do"]),
        ConnectorSpec(id: "stripe", name: "Stripe", route: .hostedMCP(url: "https://mcp.stripe.com"), auth: .discoveredOAuth,
                      aliases: ["stripe", "invoice", "invoices", "payment", "payments", "customer", "customers", "refund", "subscription"]),
        ConnectorSpec(id: "slack", name: "Slack", route: .hostedMCP(url: "https://mcp.slack.com/mcp"),
                      auth: .configuredOAuth(authorize: "https://slack.com/oauth/v2_user/authorize", token: "https://slack.com/api/oauth.v2.user.access",
                                             scopes: ["search:read.public", "search:read.private", "search:read.im", "search:read.mpim", "search:read.files", "search:read.users",
                                                      "channels:history", "groups:history", "im:history", "mpim:history", "chat:write",
                                                      "canvases:read", "canvases:write", "users:read", "users:read.email"],
                                             extra: [:]),
                      aliases: ["slack", "channel", "channels", "dm"]),
        ConnectorSpec(id: "github", name: "GitHub",
                      route: .stdioMCP(command: "github-mcp-server", arguments: ["stdio", "--toolsets", "context,repos,issues,pull_requests,notifications"],
                                       tokenVariable: "GITHUB_PERSONAL_ACCESS_TOKEN"),
                      auth: .token(label: "Personal access token", help: "Create a fine-grained token at github.com/settings/personal-access-tokens with only the repositories and permissions you want Halo to use."),
                      aliases: ["github", "repo", "repos", "repository", "pull", "pr", "prs", "issue", "issues"]),
        ConnectorSpec(id: "google", name: "Google (Gmail, Calendar, Drive, Sheets)",
                      route: .localHTTPMCP(command: "uvx", arguments: ["workspace-mcp==\(workspaceServerVersion)", "--transport", "streamable-http",
                                                                         "--tools", "gmail", "calendar", "drive", "sheets"],
                                           environment: ["MCP_ENABLE_OAUTH21": "true", "EXTERNAL_OAUTH21_PROVIDER": "true",
                                                         "WORKSPACE_MCP_STATELESS_MODE": "true", "WORKSPACE_MCP_HOST": "127.0.0.1"]),
                      auth: .configuredOAuth(authorize: "https://accounts.google.com/o/oauth2/v2/auth", token: "https://oauth2.googleapis.com/token",
                                             scopes: ["openid", "https://www.googleapis.com/auth/userinfo.email",
                                                      "https://www.googleapis.com/auth/gmail.modify", "https://www.googleapis.com/auth/calendar",
                                                      "https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/spreadsheets"],
                                             extra: ["access_type": "offline", "prompt": "consent"]),
                      apps: ["gmail", "calendar", "drive", "sheets"],
                      aliases: ["gmail", "email", "emails", "mail", "inbox", "calendar", "event", "events", "meeting", "meetings", "schedule",
                                "drive", "doc", "docs", "document", "file", "files", "sheet", "sheets", "spreadsheet", "spreadsheets"],
                      appForTool: googleApp),
        ConnectorSpec(id: "telegram", name: "Telegram", route: .directAPI,
                      auth: .token(label: "Bot token", help: "Create a bot with @BotFather and paste its token. The bot can only message people who have started a chat with it."),
                      aliases: ["telegram"]),
        ConnectorSpec(id: "discord", name: "Discord", route: .directAPI,
                      auth: .token(label: "Bot token", help: "Create an application at discord.com/developers, add a bot, and invite it to your server. Halo never uses your personal Discord login."),
                      aliases: ["discord"]),
    ]

    /// workspace-mcp names its tools after the service (search_gmail_messages,
    /// get_events, list_drive_items, read_sheet_values); the rest are Sheets tools.
    @Sendable static func googleApp(_ tool: String) -> String {
        let name = tool.lowercased()
        if name.contains("gmail") { return "gmail" }
        if ["calendar", "event", "out_of_office", "focus_time", "freebusy"].contains(where: name.contains) { return "calendar" }
        if name.contains("drive") || name.hasPrefix("import_to_google") { return "drive" }
        return "sheets"
    }

    public static func spec(_ id: String) -> ConnectorSpec? { catalog.first { $0.id == id } }
}
