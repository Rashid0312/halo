import Foundation
import AppKit

public struct BrowserTab: Sendable, Codable, Equatable {
    public let id: Int
    public let title: String
    public let url: String
    public let domain: String
    public let isActive: Bool
    public let isAuthorized: Bool
    public let windowIndex: Int
    public let tabIndex: Int

    public init(
        id: Int,
        title: String,
        url: String,
        domain: String,
        isActive: Bool,
        isAuthorized: Bool,
        windowIndex: Int = 1,
        tabIndex: Int = 1
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.domain = domain
        self.isActive = isActive
        self.isAuthorized = isAuthorized
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
    }
}

public struct BrowserTabContent: Sendable, Codable {
    public let id: Int
    public let title: String
    public let url: String
    public let domain: String
    public let content: String
    public let truncated: Bool

    public init(
        id: Int,
        title: String,
        url: String,
        domain: String,
        content: String,
        truncated: Bool
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.domain = domain
        self.content = content
        self.truncated = truncated
    }
}

public struct AuthorizedTabRecord: Sendable, Codable, Equatable {
    public let id: Int
    public let domain: String
    public let title: String
    public let url: String
    public let authorizedAt: Date

    public init(id: Int, domain: String, title: String, url: String, authorizedAt: Date = Date()) {
        self.id = id
        self.domain = domain
        self.title = title
        self.url = url
        self.authorizedAt = authorizedAt
    }
}

/// Service providing observation and access to explicitly authorized Chrome/Chromium tabs.
/// Strictly enforces per-tab authorization with domain binding, filters incognito windows and internal browser URLs,
/// never touches browser profiles or credentials, and provides instant pause/revocation killswitches.
public actor ChromeBrowserService {
    public static let shared = ChromeBrowserService()

    private var authorizedTabs: [Int: AuthorizedTabRecord] = [:]
    private var isPaused = false

    public static let supportedBrowserBundleIDs: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    public init() {}

    public func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    public func isAccessPaused() -> Bool {
        isPaused
    }

    public func isAuthorized(tabID: Int) -> Bool {
        authorizedTabs[tabID] != nil
    }

    public func authorize(tabID: Int, domain: String, title: String, url: String) {
        authorizedTabs[tabID] = AuthorizedTabRecord(
            id: tabID,
            domain: domain.lowercased(),
            title: title,
            url: url,
            authorizedAt: Date()
        )
    }

    public func revoke(tabID: Int) {
        authorizedTabs.removeValue(forKey: tabID)
    }

    public func revokeAll() {
        authorizedTabs.removeAll()
    }

    public func authorizedCount() -> Int {
        authorizedTabs.count
    }

    public func resolveBrowserAppName(_ browserAppID: String?) throws -> String {
        if let browserAppID {
            if let name = Self.supportedBrowserBundleIDs[browserAppID] {
                return name
            }
        }
        let running = NSWorkspace.shared.runningApplications
        for (bundleID, name) in Self.supportedBrowserBundleIDs {
            if running.contains(where: { $0.bundleIdentifier == bundleID }) {
                return name
            }
        }
        throw InteractionError("No supported Chromium browser (Google Chrome, Brave, Chromium, Edge) is currently running.")
    }

    private func runAppleScript(_ script: String) async throws -> String {
        try Task.checkCancellation()
        let result = try await CommandRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", script],
            directory: FileManager.default.temporaryDirectory,
            timeout: 10
        )
        guard result.status == 0 else {
            throw InteractionError("Browser automation error: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    public func openTab(url: String, browserAppID: String? = nil) async throws -> Int {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw InteractionError("Only HTTP/HTTPS URLs are allowed.")
        }
        let browserName = try resolveBrowserAppName(browserAppID)
        let escapedURL = url
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "\(browserName)"
            if not (exists front window) then make new window
            set newTab to make new tab at end of tabs of front window with properties {URL:"\(escapedURL)"}
            return (id of newTab as string)
        end tell
        """
        let raw = try await runAppleScript(script)
        guard let tabID = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InteractionError("Failed to open tab in \(browserName)")
        }
        return tabID
    }

    public func closeTab(id: Int, browserAppID: String? = nil) async throws {
        let browserName = try resolveBrowserAppName(browserAppID)
        let script = """
        tell application "\(browserName)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as string) is "\(id)" then
                        close t
                        return "CLOSED"
                    end if
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """
        _ = try? await runAppleScript(script)
        authorizedTabs.removeValue(forKey: id)
    }

    public func listTabs(browserAppID: String? = nil, authorizedOnly: Bool = false) async throws -> [BrowserTab] {
        guard !isPaused else {
            throw InteractionError("Browser tab access is currently paused.")
        }
        let browserName = try resolveBrowserAppName(browserAppID)
        // Use non-printable ASCII control characters: 0x1F (unit separator) for fields, 0x1E (record separator) for tab records.
        // This makes parsing completely immune to delimiter collisions with webpage titles or URLs.
        let script = """
        tell application "\(browserName)"
            if not (exists front window) then return ""
            set outList to {}
            repeat with w in windows
                if mode of w is not "incognito" then
                    set actIndex to active tab index of w
                    set tIdx to 1
                    repeat with t in tabs of w
                        set end of outList to (id of t as string) & (character id 31) & (title of t) & (character id 31) & (URL of t) & (character id 31) & (actIndex as string) & (character id 31) & (tIdx as string)
                        set tIdx to tIdx + 1
                    end repeat
                end if
            end repeat
            set AppleScript's text item delimiters to (character id 30)
            return outList as text
        end tell
        """
        let raw = try await runAppleScript(script)
        var tabs: [BrowserTab] = []
        let records = raw.components(separatedBy: "\u{1E}")
        for record in records {
            let parts = record.components(separatedBy: "\u{1F}")
            guard parts.count >= 5,
                  let id = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let activeIdx = Int(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let tabIdx = Int(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) else {
                continue
            }
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let url = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)

            // Filter out internal or unsupported schemes (chrome://, chrome-extension://, about:, file://, devtools://)
            guard let parsedURL = URL(string: url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme) else {
                continue
            }
            let domain = parsedURL.host ?? "browser"
            let isActive = (activeIdx == tabIdx)
            let authorized = (authorizedTabs[id] != nil)

            if authorizedOnly && !authorized {
                continue
            }

            tabs.append(BrowserTab(
                id: id,
                title: String(title.prefix(200)),
                url: url,
                domain: domain,
                isActive: isActive,
                isAuthorized: authorized,
                windowIndex: 1,
                tabIndex: tabIdx
            ))
            if tabs.count >= 50 { break }
        }
        return tabs
    }

    public func activeTab(browserAppID: String? = nil) async throws -> BrowserTab? {
        let tabs = try await listTabs(browserAppID: browserAppID, authorizedOnly: false)
        return tabs.first(where: { $0.isActive }) ?? tabs.first
    }

    public func readTab(id: Int, browserAppID: String? = nil) async throws -> BrowserTabContent {
        guard !isPaused else {
            throw InteractionError("Browser tab access is currently paused.")
        }
        guard let record = authorizedTabs[id] else {
            throw InteractionError("Tab \(id) is not authorized. The user must explicitly authorize this tab before its contents can be read.")
        }
        let browserName = try resolveBrowserAppName(browserAppID)
        // Return JSON from the browser DOM directly. JSON.stringify safely handles quotes, escapes, unicode, and newlines.
        let script = """
        tell application "\(browserName)"
            repeat with w in windows
                if mode of w is not "incognito" then
                    repeat with t in tabs of w
                        if (id of t as string) is "\(id)" then
                            set jsonStr to execute t javascript "JSON.stringify({title: document.title || '', url: window.location.href || '', text: (document.body ? (document.body.innerText || '') : '').slice(0, 16000)})"
                            return jsonStr
                        end if
                    end repeat
                end if
            end repeat
            return "NOT_FOUND"
        end tell
        """
        let raw = try await runAppleScript(script)
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
            authorizedTabs.removeValue(forKey: id)
            throw InteractionError("Tab \(id) was not found in non-incognito windows.")
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String,
              let url = json["url"] as? String,
              let content = json["text"] as? String else {
            throw InteractionError("Failed to parse tab content from browser.")
        }

        // Recheck pause state after execution before returning data (defense-in-depth against race conditions)
        guard !isPaused else {
            throw InteractionError("Browser tab access is currently paused.")
        }

        guard let parsedURL = URL(string: url),
              let scheme = parsedURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            authorizedTabs.removeValue(forKey: id)
            throw InteractionError("Reading internal browser pages is strictly forbidden.")
        }
        let domain = (parsedURL.host ?? "browser").lowercased()

        // Domain binding check: if the tab was navigated to a different domain, revoke authorization immediately
        guard domain == record.domain else {
            authorizedTabs.removeValue(forKey: id)
            throw InteractionError("Security violation: Tab \(id) has navigated from authorized domain '\(record.domain)' to '\(domain)'. Access has been revoked.")
        }

        let truncated = content.count >= 16000

        return BrowserTabContent(
            id: id,
            title: String(title.prefix(200)),
            url: url,
            domain: domain,
            content: content,
            truncated: truncated
        )
    }
}
