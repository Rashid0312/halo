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
    public let browserBundleID: String
    public let browserPID: Int32
    public let browserSessionID: String

    public init(id: Int, title: String, url: String, domain: String, isActive: Bool,
                isAuthorized: Bool, windowIndex: Int = 1, tabIndex: Int = 1,
                browserBundleID: String = "", browserPID: Int32 = 0,
                browserSessionID: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.domain = domain
        self.isActive = isActive
        self.isAuthorized = isAuthorized
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.browserBundleID = browserBundleID
        self.browserPID = browserPID
        self.browserSessionID = browserSessionID
    }
}

public struct BrowserTabContent: Sendable, Codable {
    public let id: Int
    public let title: String
    public let url: String
    public let domain: String
    public let content: String
    public let truncated: Bool
}

public struct AuthorizedTabKey: Sendable, Codable, Hashable {
    public let browserBundleID: String
    public let browserSessionID: String
    public let tabID: Int
}

public struct AuthorizedTabRecord: Sendable, Codable, Equatable {
    public let key: AuthorizedTabKey
    public let domain: String
    public let title: String
    public let url: String
    public let authorizedAt: Date
}

internal protocol BrowserAutomationRuntime: Sendable {
    func resolveBrowserContext(_ requestedBundleID: String?) throws -> ChromeBrowserService.BrowserContext
    func runAppleScript(_ script: String) async throws -> String
}

internal struct SystemBrowserRuntime: BrowserAutomationRuntime {
    func resolveBrowserContext(_ requestedBundleID: String?) throws -> ChromeBrowserService.BrowserContext {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let app: NSRunningApplication
        let bundleID: String

        if let requestedBundleID {
            guard ChromeBrowserService.supportedBrowserBundleIDs[requestedBundleID] != nil else {
                throw InteractionError("Unsupported Chromium browser bundle ID '\(requestedBundleID)'.")
            }
            guard let exact = running.first(where: { $0.bundleIdentifier == requestedBundleID }) else {
                throw InteractionError("The requested Chromium browser is not running.")
            }
            app = exact
            bundleID = requestedBundleID
        } else {
            let candidates = running.filter { candidate in
                candidate.bundleIdentifier.map { ChromeBrowserService.supportedBrowserBundleIDs[$0] != nil } == true
            }
            guard let selected = candidates.first(where: { $0.isActive }) ?? candidates.sorted(by: {
                ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "")
            }).first, let selectedID = selected.bundleIdentifier else {
                throw InteractionError("No supported Chromium browser (Google Chrome, Brave, Chromium, Edge) is currently running.")
            }
            app = selected
            bundleID = selectedID
        }

        let launched = app.launchDate?.timeIntervalSince1970 ?? 0
        return ChromeBrowserService.BrowserContext(bundleID: bundleID,
                                                   name: ChromeBrowserService.supportedBrowserBundleIDs[bundleID]!,
                                                   pid: app.processIdentifier,
                                                   sessionID: "\(app.processIdentifier):\(launched)")
    }

    func runAppleScript(_ script: String) async throws -> String {
        try Task.checkCancellation()
        let result = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script],
                                                 directory: FileManager.default.temporaryDirectory, timeout: 10)
        guard result.status == 0 else {
            throw InteractionError("Browser automation error: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }
}

/// Read-only, explicitly authorized access to non-incognito Chromium tabs.
/// Authorization is scoped to a browser process session and tab. An access epoch
/// ensures pause and revocation win over results already in flight.
public actor ChromeBrowserService {
    public static let shared = ChromeBrowserService()

    internal struct BrowserContext: Sendable, Equatable {
        let bundleID: String
        let name: String
        let pid: pid_t
        let sessionID: String

        init(bundleID: String, name: String, pid: pid_t, sessionID: String) {
            self.bundleID = bundleID
            self.name = name
            self.pid = pid
            self.sessionID = sessionID
        }
    }

    private let runtime: any BrowserAutomationRuntime
    private var authorizedTabs: [AuthorizedTabKey: AuthorizedTabRecord] = [:]
    private var isPaused = false
    private var accessEpoch: UInt64 = 0

    public static let supportedBrowserBundleIDs: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    public init() {
        self.runtime = SystemBrowserRuntime()
    }

    internal init(runtime: any BrowserAutomationRuntime) {
        self.runtime = runtime
    }

    public func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        accessEpoch &+= 1
    }

    public func isAccessPaused() -> Bool { isPaused }

    public func isAuthorized(tabID: Int) -> Bool {
        authorizedTabs.keys.contains { $0.tabID == tabID }
    }

    public func revoke(tabID: Int, browserAppID: String? = nil) {
        authorizedTabs = authorizedTabs.filter { key, _ in
            key.tabID != tabID || (browserAppID != nil && key.browserBundleID != browserAppID)
        }
        accessEpoch &+= 1
    }

    public func revokeAll() {
        authorizedTabs.removeAll()
        accessEpoch &+= 1
    }

    public func authorizedCount() -> Int { authorizedTabs.count }

    private func browserContext(_ requestedBundleID: String?) throws -> BrowserContext {
        try runtime.resolveBrowserContext(requestedBundleID)
    }

    public func resolveBrowserAppName(_ browserAppID: String?) throws -> String {
        try browserContext(browserAppID).name
    }

    private func runAppleScript(_ script: String) async throws -> String {
        try await runtime.runAppleScript(script)
    }

    public func openTab(url: String, browserAppID: String? = nil) async throws -> Int {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { throw InteractionError("Only HTTP/HTTPS URLs are allowed.") }
        let context = try browserContext(browserAppID)
        let escaped = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let raw = try await runAppleScript("""
        tell application "\(context.name)"
            if not (exists front window) then make new window
            set newTab to make new tab at end of tabs of front window with properties {URL:"\(escaped)"}
            return (id of newTab as string)
        end tell
        """)
        guard let id = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InteractionError("Failed to open tab in \(context.name)")
        }
        return id
    }

    public func closeTab(id: Int, browserAppID: String? = nil) async throws {
        let context = try browserContext(browserAppID)
        _ = try? await runAppleScript("""
        tell application "\(context.name)"
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
        """)
        revoke(tabID: id, browserAppID: context.bundleID)
    }

    private func tabKey(_ id: Int, context: BrowserContext) -> AuthorizedTabKey {
        AuthorizedTabKey(browserBundleID: context.bundleID, browserSessionID: context.sessionID, tabID: id)
    }

    public func listTabs(browserAppID: String? = nil, authorizedOnly: Bool = false) async throws -> [BrowserTab] {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let epoch = accessEpoch
        let context = try browserContext(browserAppID)
        // Sanitize both framing characters inside AppleScript before concatenation.
        // This keeps tab enumeration independent of Chrome's optional JavaScript-from-
        // Apple-Events setting while strict field counts reject malformed output.
        let raw = try await runAppleScript("""
        on replaceText(findText, replacementText, sourceText)
            set oldDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to findText
            set sourceItems to text items of sourceText
            set AppleScript's text item delimiters to replacementText
            set sourceText to sourceItems as text
            set AppleScript's text item delimiters to oldDelimiters
            return sourceText
        end replaceText
        tell application "\(context.name)"
            if not (exists front window) then return ""
            set outList to {}
            set wIdx to 1
            repeat with w in windows
                if mode of w is not "incognito" then
                    set actIndex to active tab index of w
                    set tIdx to 1
                    repeat with t in tabs of w
                        set safeTitle to my replaceText(character id 31, "�", title of t)
                        set safeTitle to my replaceText(character id 30, "�", safeTitle)
                        set safeURL to my replaceText(character id 31, "�", URL of t)
                        set safeURL to my replaceText(character id 30, "�", safeURL)
                        set end of outList to (id of t as string) & (character id 31) & (actIndex as string) & (character id 31) & (tIdx as string) & (character id 31) & (wIdx as string) & (character id 31) & safeTitle & (character id 31) & safeURL
                        set tIdx to tIdx + 1
                    end repeat
                end if
                set wIdx to wIdx + 1
            end repeat
            set AppleScript's text item delimiters to (character id 30)
            return outList as text
        end tell
        """)
        try Task.checkCancellation()
        guard !isPaused, epoch == accessEpoch else {
            throw InteractionError("Browser tab access changed while the listing was in flight.")
        }
        let current = try browserContext(context.bundleID)
        guard current.sessionID == context.sessionID else {
            throw InteractionError("The browser restarted while tabs were being listed.")
        }

        var tabs: [BrowserTab] = []
        for record in raw.components(separatedBy: "\u{1E}") where !record.isEmpty {
            let parts = record.components(separatedBy: "\u{1F}")
            guard parts.count == 6,
                  let id = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  let active = Int(parts[1]), let tabIndex = Int(parts[2]), let windowIndex = Int(parts[3]) else {
                throw InteractionError("Malformed browser tab metadata; no tabs were returned.")
            }
            let title = parts[4]
            let url = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
                  ["http", "https"].contains(scheme), let host = parsed.host else { continue }
            let authorized = authorizedTabs[tabKey(id, context: context)] != nil
            if authorizedOnly && !authorized { continue }
            tabs.append(BrowserTab(id: id, title: String(title.prefix(200)), url: url,
                                   domain: host.lowercased(), isActive: active == tabIndex,
                                   isAuthorized: authorized, windowIndex: windowIndex, tabIndex: tabIndex,
                                   browserBundleID: context.bundleID, browserPID: context.pid,
                                   browserSessionID: context.sessionID))
            if tabs.count >= 50 { break }
        }
        return tabs
    }

    public func activeTab(browserAppID: String? = nil) async throws -> BrowserTab? {
        let tabs = try await listTabs(browserAppID: browserAppID, authorizedOnly: false)
        return tabs.first(where: { $0.isActive }) ?? tabs.first
    }

    /// Re-observes after approval and authorizes only an unchanged browser-session/tab/URL.
    public func authorizeObservedTab(_ approved: BrowserTab) async throws -> AuthorizedTabRecord {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let tabs = try await listTabs(browserAppID: approved.browserBundleID, authorizedOnly: false)
        guard let current = tabs.first(where: { $0.id == approved.id }),
              current.browserSessionID == approved.browserSessionID,
              current.url == approved.url, current.domain == approved.domain else {
            throw InteractionError("The browser tab changed while approval was open. Inspect it and approve again.")
        }
        let key = AuthorizedTabKey(browserBundleID: current.browserBundleID,
                                   browserSessionID: current.browserSessionID, tabID: current.id)
        let record = AuthorizedTabRecord(key: key, domain: current.domain, title: current.title,
                                         url: current.url, authorizedAt: Date())
        authorizedTabs[key] = record
        accessEpoch &+= 1
        return record
    }

    public func readTab(id: Int, browserAppID: String? = nil) async throws -> BrowserTabContent {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let context = try browserContext(browserAppID)
        let key = tabKey(id, context: context)
        guard let record = authorizedTabs[key] else {
            throw InteractionError("Tab \(id) is not authorized for this browser session.")
        }
        let epoch = accessEpoch
        let raw = try await runAppleScript("""
        tell application "\(context.name)"
            repeat with w in windows
                if mode of w is not "incognito" then
                    repeat with t in tabs of w
                        if (id of t as string) is "\(id)" then
                            return execute t javascript "JSON.stringify({title: document.title || '', url: window.location.href || '', text: (document.body ? (document.body.innerText || '') : '').slice(0, 16000)})"
                        end if
                    end repeat
                end if
            end repeat
            return "NOT_FOUND"
        end tell
        """)
        try Task.checkCancellation()
        guard !isPaused, epoch == accessEpoch, authorizedTabs[key] == record else {
            throw InteractionError("Browser tab access changed while the read was in flight.")
        }
        let currentContext = try browserContext(context.bundleID)
        guard currentContext.sessionID == context.sessionID else {
            authorizedTabs.removeValue(forKey: key)
            throw InteractionError("The browser restarted; tab authorization was revoked.")
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "NOT_FOUND" {
            authorizedTabs.removeValue(forKey: key)
            throw InteractionError("Tab \(id) was not found in non-incognito windows.")
        }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String, let url = json["url"] as? String,
              let content = json["text"] as? String else {
            throw InteractionError("Failed to parse tab content from browser.")
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parsed.host else {
            authorizedTabs.removeValue(forKey: key)
            throw InteractionError("Reading internal browser pages is strictly forbidden.")
        }
        let domain = host.lowercased()
        guard domain == record.domain else {
            authorizedTabs.removeValue(forKey: key)
            throw InteractionError("Tab \(id) navigated from '\(record.domain)' to '\(domain)'; authorization was revoked.")
        }
        return BrowserTabContent(id: id, title: String(title.prefix(200)), url: url, domain: domain,
                                 content: content, truncated: content.utf16.count >= 16000)
    }
}
