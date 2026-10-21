import Foundation
import AppKit
import HaloBridge
import HaloCore

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
    /// Element references from a bridge observation; empty on the AppleScript path.
    public var elements: [BrowserTabElement] = []
}

/// An element reference the model may cite. IDs are opaque and valid only for
/// the document they were observed in.
public struct BrowserTabElement: Sendable, Codable, Equatable {
    public let id: String
    public let role: String
    public let tagName: String
    public let label: String
    public let clickable: Bool
    public let typable: Bool
    public var selectable = false
    public var scrollable = false
    public var options: [String] = []
    /// Phase 5B.4: what a click does (button, submit, link) when clickable.
    public var clickKind: String?
    /// Phase 5B.4: why a click is blocked, in plain words.
    public var blocked: String?
}

/// Outcome of an approved navigation.
public struct BrowserNavigationResult: Sendable {
    public let url: String
    /// False when the destination left the authorized domain: access ended.
    public let stillAuthorized: Bool
}

public enum BrowserElementAction: Sendable { case click, type, select, scroll }

/// An element re-observed immediately before approval. The approval preview
/// shows these fields; the action is refused if any of them no longer hold.
public struct BrowserElementTarget: Sendable, Equatable {
    public let tabID: Int
    public let title: String
    public let url: String
    public let domain: String
    public let elementID: String
    public let tagName: String
    public let role: String
    public let label: String
    /// Offered option labels when the target is a dropdown.
    public var options: [String] = []
    /// Phase 5B.4: approved click kind, destination, and the fields a submit sends.
    public var clickKind: BridgeClickKind?
    public var destination: String?
    public var formFields: [BridgeFormField] = []
    let key: AuthorizedTabKey
    let generation: UInt64

    /// Reference used for actions on the whole page rather than one element.
    static let pageReference = "el_page"
    var isPage: Bool { elementID == Self.pageReference }
}

public struct BrowserClickResult: Sendable {
    /// True when the extension confirmed the action took effect (click landed,
    /// form submitted, link navigated, text or option matched, view scrolled).
    public let verified: Bool
    /// Fresh observation after the action, when the page is still readable.
    public let after: BrowserTabContent?
    /// False when the action left the authorized site and access ended.
    public var stillAuthorized = true
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

/// Remembers which supported browser the user activated most recently, so an
/// unnamed browser request means "the browser I was just using" rather than
/// whichever app happens to be frontmost (Halo's own panel can be).
final class BrowserActivityTracker: @unchecked Sendable {
    static let shared = BrowserActivityTracker()
    private let lock = NSLock()
    private var lastActiveBundleID: String?
    private var observer: NSObjectProtocol?

    /// Starts observing app activation. Safe to call more than once.
    func start() {
        lock.withLock {
            guard observer == nil else { return }
            if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
               ChromeBrowserService.supportedBrowserBundleIDs[front] != nil {
                lastActiveBundleID = front
            }
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier, ChromeBrowserService.supportedBrowserBundleIDs[id] != nil else { return }
                self?.lock.withLock { self?.lastActiveBundleID = id }
            }
        }
    }

    var lastActive: String? { lock.withLock { lastActiveBundleID } }
}

internal struct SystemBrowserRuntime: BrowserAutomationRuntime {
    struct RunningBrowser: Equatable {
        let bundleID: String
        let pid: pid_t
        let launched: TimeInterval
    }

    /// Picks exactly one running browser instance, or explains why it cannot.
    /// - One supported browser: use it.
    /// - Several different browsers: the one most recently activated, if known;
    ///   otherwise refuse and ask which.
    /// - Several instances of the chosen browser (separate profiles or test
    ///   copies): refuse, since AppleScript cannot address a specific instance.
    static func choose(from running: [RunningBrowser], requested rawRequest: String?, lastActive: String?) throws -> RunningBrowser {
        let supported = running.filter { ChromeBrowserService.supportedBrowserBundleIDs[$0.bundleID] != nil }
        let bundleID: String
        if let rawRequest {
            guard let requested = ChromeBrowserService.browserBundleID(for: rawRequest) else {
                throw InteractionError("'\(rawRequest)' is not a supported browser. Halo's browser tools work with Google Chrome, Brave, Microsoft Edge, and Chromium; leave browser_app_id out to use the one that is open.")
            }
            guard supported.contains(where: { $0.bundleID == requested }) else {
                throw InteractionError("The requested Chromium browser is not running.")
            }
            bundleID = requested
        } else {
            let open = Set(supported.map(\.bundleID))
            if open.count == 1, let only = open.first {
                bundleID = only
            } else if let lastActive, open.contains(lastActive) {
                bundleID = lastActive
            } else if open.isEmpty {
                throw InteractionError("No supported Chromium browser (Google Chrome, Brave, Chromium, Edge) is currently running.")
            } else {
                let names = open.compactMap { ChromeBrowserService.supportedBrowserBundleIDs[$0] }.sorted().joined(separator: ", ")
                throw InteractionError("Several browsers are open (\(names)). Say which one to use with browser_app_id.")
            }
        }
        let instances = supported.filter { $0.bundleID == bundleID }
        guard instances.count == 1, let instance = instances.first else {
            let name = ChromeBrowserService.supportedBrowserBundleIDs[bundleID] ?? bundleID
            throw InteractionError("\(name) is running more than once (separate profiles or copies), so Halo cannot tell which one to use. Quit the extra copies and try again.")
        }
        return instance
    }

    func resolveBrowserContext(_ requestedBundleID: String?) throws -> ChromeBrowserService.BrowserContext {
        BrowserActivityTracker.shared.start()
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> RunningBrowser? in
            guard !app.isTerminated, let id = app.bundleIdentifier else { return nil }
            return RunningBrowser(bundleID: id, pid: app.processIdentifier, launched: app.launchDate?.timeIntervalSince1970 ?? 0)
        }
        let chosen = try Self.choose(from: running, requested: requestedBundleID, lastActive: BrowserActivityTracker.shared.lastActive)
        return ChromeBrowserService.BrowserContext(bundleID: chosen.bundleID,
                                                   name: ChromeBrowserService.supportedBrowserBundleIDs[chosen.bundleID]!,
                                                   pid: chosen.pid,
                                                   sessionID: "\(chosen.pid):\(chosen.launched)")
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
    private var bridgeServer: BridgeIPCServer? = nil
    private var bridgeValidator: BridgeSessionValidator? = nil
    private var bridgeGenerations: [AuthorizedTabKey: UInt64] = [:]
    private var bridgeReadInFlight = false
    /// Origins where Chrome withheld the extension's access at the last read.
    private var siteAccessWithheld = Set<String>()
    /// Latest bridge observation per tab, bound to the document generation it came from.
    private var bridgeElements: [AuthorizedTabKey: (generation: UInt64, elements: [String: ObservedDOMElement])] = [:]
    /// Text Halo typed per document, shown in submit approvals. Values the user
    /// typed are never read; only Halo's own text is known.
    private var typedTexts: [AuthorizedTabKey: (generation: UInt64, texts: [String: String])] = [:]

    public func attachBridgeServer(_ server: BridgeIPCServer) {
        self.bridgeServer = server
        self.bridgeValidator = BridgeSessionValidator(sessionNonce: server.sessionConfig.sessionNonce)
        self.bridgeGenerations.removeAll()
        self.bridgeElements.removeAll()
    }

    private enum BridgeMessageKind { case event(AuthorizedTabKey), response }

    /// Applies an unsolicited navigation or tab-close event to the authorization
    /// state. Events that cannot be reconciled revoke the tab (fail closed).
    private func applyBridgeMessage(_ message: BridgeResponse, nonce: String,
                                    validator: BridgeSessionValidator) async throws -> BridgeMessageKind {
        if let navigation = message.navigation {
            guard BridgeSessionValidator.constantTimeEquals(message.sessionNonce, nonce) else {
                throw BridgeErrorDetails(code: .authenticationFailed, message: "Navigation event session mismatch.")
            }
            let key = AuthorizedTabKey(browserBundleID: navigation.browser.bundleID,
                                       browserSessionID: navigation.browser.sessionID, tabID: navigation.tabID)
            // The extension's generation is authoritative for every tab it has bound,
            // authorized or not, so a later re-approval targets the live document.
            bridgeGenerations[key] = navigation.newDocumentGenerationID
            if let record = authorizedTabs[key] {
                do {
                    try await validator.notifyNavigation(event: navigation)
                    if navigation.newDomain.lowercased() != record.domain.lowercased() {
                        authorizedTabs.removeValue(forKey: key)
                    } else {
                        // Authorization is domain-bound; follow same-site navigation.
                        authorizedTabs[key] = AuthorizedTabRecord(key: key, domain: record.domain, title: record.title,
                                                                  url: navigation.newURL, authorizedAt: record.authorizedAt)
                    }
                } catch {
                    authorizedTabs.removeValue(forKey: key)
                }
                accessEpoch &+= 1
            }
            return .event(key)
        }
        if let closed = message.tabClosed {
            guard BridgeSessionValidator.constantTimeEquals(message.sessionNonce, nonce) else {
                throw BridgeErrorDetails(code: .authenticationFailed, message: "Tab-close event session mismatch.")
            }
            let key = AuthorizedTabKey(browserBundleID: closed.browser.bundleID,
                                       browserSessionID: closed.browser.sessionID, tabID: closed.tabID)
            try? await validator.notifyClosed(event: closed)
            bridgeGenerations.removeValue(forKey: key)
            if authorizedTabs.removeValue(forKey: key) != nil {
                accessEpoch &+= 1
            }
            return .event(key)
        }
        return .response
    }

    public func detachBridgeServer() {
        self.bridgeServer = nil
        self.bridgeValidator = nil
        self.bridgeGenerations.removeAll()
        self.bridgeElements.removeAll()
    }

    public func activeBridgeServer() -> BridgeIPCServer? {
        bridgeServer
    }

    public static let supportedBrowserBundleIDs: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "com.brave.Browser": "Brave Browser",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    /// A supported bundle ID for a bundle ID or a browser's name ("Google
    /// Chrome", "chrome", "Brave"), since models often pass the name.
    public static func browserBundleID(for raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if supportedBrowserBundleIDs[text] != nil { return text }
        let lower = text.lowercased()
        if let match = supportedBrowserBundleIDs.first(where: { $0.key.lowercased() == lower || $0.value.lowercased() == lower }) { return match.key }
        return ["chrome": "com.google.Chrome", "google chrome": "com.google.Chrome", "brave": "com.brave.Browser",
                "edge": "com.microsoft.edgemac", "chromium": "org.chromium.Chromium"][lower]
    }

    public init() {
        self.runtime = SystemBrowserRuntime()
    }

    internal init(runtime: any BrowserAutomationRuntime) {
        self.runtime = runtime
    }

    public func setPaused(_ paused: Bool) async {
        guard isPaused != paused else { return }
        isPaused = paused
        accessEpoch &+= 1
        await bridgeValidator?.setPaused(paused)
    }

    public func isAccessPaused() -> Bool { isPaused }

    public func isAuthorized(tabID: Int) -> Bool {
        authorizedTabs.keys.contains { $0.tabID == tabID }
    }

    public func revoke(tabID: Int, browserAppID rawBrowserAppID: String? = nil) async {
        let browserAppID = rawBrowserAppID.map { Self.browserBundleID(for: $0) ?? $0 }
        let revokedKeys = authorizedTabs.keys.filter { key in
            key.tabID == tabID && (browserAppID == nil || key.browserBundleID == browserAppID)
        }
        if let validator = bridgeValidator {
            for key in revokedKeys {
                if let record = authorizedTabs[key] {
                    let browser = BrowserIdentity(bundleID: key.browserBundleID, sessionID: key.browserSessionID,
                                                  pid: (try? browserContext(key.browserBundleID).pid) ?? 1)
                    let identity = TabGenerationIdentity(browser: browser, tabID: key.tabID,
                        documentGenerationID: bridgeGenerations[key] ?? 1, url: record.url, domain: record.domain)
                    await validator.revokeTab(identity)
                }
            }
        }
        authorizedTabs = authorizedTabs.filter { key, _ in
            key.tabID != tabID || (browserAppID != nil && key.browserBundleID != browserAppID)
        }
        accessEpoch &+= 1
    }

    public func revokeAll() async {
        if let validator = bridgeValidator {
            for (key, record) in authorizedTabs {
                let browser = BrowserIdentity(bundleID: key.browserBundleID, sessionID: key.browserSessionID,
                                              pid: (try? browserContext(key.browserBundleID).pid) ?? 1)
                await validator.revokeTab(TabGenerationIdentity(browser: browser, tabID: key.tabID,
                    documentGenerationID: bridgeGenerations[key] ?? 1, url: record.url, domain: record.domain))
            }
        }
        authorizedTabs.removeAll()
        bridgeGenerations.removeAll()
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

    public enum TabCommand: String, Sendable { case reload, back, forward, switchTo }

    /// Closes tabs by id, one AppleScript per tab so indexes never shift under
    /// the loop. Returns the ids that were found and closed.
    public func closeTabs(ids: [Int], browserAppID: String? = nil) async throws -> [Int] {
        var closed: [Int] = []
        for id in ids {
            let context = try browserContext(browserAppID)
            let raw = try await runAppleScript("""
            tell application "\(context.name)"
                repeat with w in windows
                    set matches to (every tab of w whose id is \(id))
                    if (count of matches) > 0 then
                        close item 1 of matches
                        return "CLOSED"
                    end if
                end repeat
                return "NOT_FOUND"
            end tell
            """)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines) == "CLOSED" { closed.append(id) }
            await revoke(tabID: id, browserAppID: context.bundleID)
        }
        return closed
    }

    /// Reload, back, forward, or bring a tab to the front of its window (Chrome
    /// itself is not activated, so the user's focus stays where it is).
    public func tabCommand(_ command: TabCommand, id: Int, browserAppID: String? = nil) async throws {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let context = try browserContext(browserAppID)
        let action: String
        switch command {
        case .reload: action = "reload t"
        case .back: action = "go back t"
        case .forward: action = "go forward t"
        case .switchTo: action = "set active tab index of w to i\n                    set index of w to 1"
        }
        let raw = try await runAppleScript("""
        tell application "\(context.name)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if (id of t) is \(id) then
                        \(action)
                        return "DONE"
                    end if
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """)
        guard raw.trimmingCharacters(in: .whitespacesAndNewlines) == "DONE" else {
            throw InteractionError("Tab \(id) was not found in open windows.")
        }
    }

    /// Opens a new browser window, optionally at an http(s) address.
    public func newWindow(url: String?, browserAppID: String? = nil) async throws {
        if let url, let refusal = Self.navigationRefusal(url) { throw InteractionError(refusal) }
        let context = try browserContext(browserAppID)
        let escaped = (url ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try await runAppleScript("""
        tell application "\(context.name)"
            set w to make new window
            \(url == nil ? "" : "set URL of active tab of w to \"\(escaped)\"")
        end tell
        """)
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
        await revoke(tabID: id, browserAppID: context.bundleID)
    }

    private func tabKey(_ id: Int, context: BrowserContext) -> AuthorizedTabKey {
        AuthorizedTabKey(browserBundleID: context.bundleID, browserSessionID: context.sessionID, tabID: id)
    }

    public func listTabs(browserAppID: String? = nil, authorizedOnly: Bool = false) async throws -> [BrowserTab] {
        TimingLog.shared.mark("  listTabs: entered service")
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let epoch = accessEpoch
        let context = try browserContext(browserAppID)
        TimingLog.shared.mark("  listTabs: browser resolved")
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
                    -- One Apple Event per property per window, not per tab.
                    set tabIDs to id of tabs of w
                    set tabTitles to title of tabs of w
                    set tabURLs to URL of tabs of w
                    repeat with tIdx from 1 to count of tabIDs
                        set safeTitle to my replaceText(character id 31, "�", item tIdx of tabTitles)
                        set safeTitle to my replaceText(character id 30, "�", safeTitle)
                        set safeURL to my replaceText(character id 31, "�", item tIdx of tabURLs)
                        set safeURL to my replaceText(character id 30, "�", safeURL)
                        set end of outList to ((item tIdx of tabIDs) as string) & (character id 31) & (actIndex as string) & (character id 31) & (tIdx as string) & (character id 31) & (wIdx as string) & (character id 31) & safeTitle & (character id 31) & safeURL
                    end repeat
                end if
                set wIdx to wIdx + 1
            end repeat
            set AppleScript's text item delimiters to (character id 30)
            return outList as text
        end tell
        """)
        TimingLog.shared.mark("  listTabs: AppleScript returned")
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
        return try await recordAuthorization(current)
    }

    /// Authorizes a tab taken from a listing made just now, with no approval
    /// window in between (the user's settings approve browser actions), so the
    /// re-listing that guards a human approval is unnecessary.
    public func authorizeListedTab(_ tab: BrowserTab) async throws -> AuthorizedTabRecord {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        return try await recordAuthorization(tab)
    }

    private func recordAuthorization(_ current: BrowserTab) async throws -> AuthorizedTabRecord {
        let key = AuthorizedTabKey(browserBundleID: current.browserBundleID,
                                   browserSessionID: current.browserSessionID, tabID: current.id)
        let record = AuthorizedTabRecord(key: key, domain: current.domain, title: current.title,
                                         url: current.url, authorizedAt: Date())
        authorizedTabs[key] = record
        accessEpoch &+= 1
        if let validator = bridgeValidator {
            let identity = TabGenerationIdentity(
                browser: BrowserIdentity(bundleID: current.browserBundleID, sessionID: current.browserSessionID, pid: current.browserPID),
                tabID: current.id, documentGenerationID: bridgeGenerations[key] ?? 1, url: current.url, domain: current.domain
            )
            try await validator.authorizeTab(identity)
        }
        return record
    }

    /// Phase 5B.1 policy, enforced by Halo independently of the extension's flag:
    /// plain, enabled, unprotected buttons only.
    static func isClickable(_ element: ObservedDOMElement, pageURL: String) -> Bool {
        clickKind(element, pageURL: pageURL) != nil
    }

    /// Scheme, host, and port of an http(s) address.
    static func origin(of url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = components.host?.lowercased() else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// Phase 5B.4: Halo's own check of what a click would do. The extension's
    /// classification must agree with the element's tag and destination.
    static func clickKind(_ element: ObservedDOMElement, pageURL: String) -> BridgeClickKind? {
        guard element.isEnabled, !element.isProtected, element.blockedReason == nil else { return nil }
        switch element.actionKind.flatMap(BridgeClickKind.init(rawValue:)) {
        case .button?:
            return element.isActionable == true && (element.tagName == "button" || element.role == "button") ? .button : nil
        case .submit?:
            // Ordinary submissions stay on the page's own origin.
            guard ["button", "input"].contains(element.tagName), let destination = element.destinationURL,
                  navigationRefusal(destination) == nil, let destinationOrigin = origin(of: destination),
                  destinationOrigin == origin(of: pageURL) else { return nil }
            return .submit
        case .link?:
            guard element.tagName == "a", let destination = element.destinationURL, navigationRefusal(destination) == nil else { return nil }
            return .link
        case nil:
            // Extensions predating 5B.4 only report plain buttons.
            return element.actionKind == nil && element.isActionable == true &&
                (element.tagName == "button" || element.role == "button") ? .button : nil
        }
    }

    /// Plain-language reason for a blocked sensitive-action family.
    static func blockedReasonText(_ reason: String) -> String {
        switch BridgeBlockedReason(rawValue: reason) {
        case .login?: "it signs in, signs up, or handles a password or one-time code"
        case .payment?: "it may buy, pay, subscribe, or handle payment details"
        case .account?: "it may change your account: delete, sign out, star, follow, like, connect, or apply"
        case .message?: "it may send or publish content"
        case .upload?: "the form uploads files"
        case .download?: "it downloads a file"
        case .crossSiteForm?: "the form sends its data to a different website"
        case .newTab?: "it opens a new tab, which Halo is not authorized to use"
        case .nonHttpLink?: "it is not a web link"
        default: "it is a sensitive action Halo does not perform yet"
        }
    }

    /// Phase 5B.2 policy, enforced by Halo independently of the extension's flag:
    /// enabled, unprotected plain text inputs and textareas only.
    static func isTypable(_ element: ObservedDOMElement) -> Bool {
        element.isEditable == true && element.isEnabled && !element.isProtected &&
            ["input", "textarea"].contains(element.tagName)
    }

    /// The development extension's `host_permissions` (Fixtures manifest). The
    /// bridge can only see these sites; every other site is read through the
    /// AppleScript path, and browser actions are unavailable there.
    static let bridgeHostPermissions = ["http://*/*", "https://*/*"]

    static func bridgeCovers(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return false }
        return bridgeHostPermissions.contains { pattern in
            guard let separator = pattern.range(of: "://") else { return false }
            let patternScheme = String(pattern[..<separator.lowerBound])
            let patternHost = pattern[separator.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            let schemeMatches = patternScheme == "*" ? ["http", "https"].contains(scheme) : patternScheme == scheme
            return schemeMatches && (patternHost == "*" || patternHost == host)
        }
    }

    private func requireSiteAccess(_ url: String) throws {
        guard let origin = Self.origin(of: url), !siteAccessWithheld.contains(origin) else {
            throw InteractionError("Chrome does not give the Halo extension access to this site, so Halo can read it but not act on it. Allow the site under the extension's Site access in Chrome to enable actions.")
        }
    }

    /// Browser actions need the bridge, which only covers its host permissions.
    private func requireBridgeCoverage(tabID: Int, browserAppID: String?) throws {
        let key = tabKey(tabID, context: try browserContext(browserAppID))
        guard let record = authorizedTabs[key] else {
            throw InteractionError("Tab \(tabID) is not authorized for this browser session.")
        }
        guard Self.bridgeCovers(record.url) else {
            throw InteractionError("Browser actions are only available on http and https pages. Reading this tab still works.")
        }
    }

    /// Phase 5B.3: enabled, unprotected single-choice dropdowns with options.
    static func isSelectable(_ element: ObservedDOMElement) -> Bool {
        element.isSelectable == true && element.isEnabled && !element.isProtected &&
            element.tagName == "select" && !(element.options ?? []).isEmpty
    }

    /// Phase 5B.3: scrollable regions reported by the extension.
    static func isScrollable(_ element: ObservedDOMElement) -> Bool {
        element.isScrollable == true && !element.isProtected
    }

    /// Why Halo refuses to navigate to `url`, or nil when it may be offered.
    static func navigationRefusal(_ url: String) -> String? {
        guard url.utf8.count <= 2_048 else { return "The address is longer than 2,048 characters." }
        guard !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " }),
              let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else {
            return "That is not a valid web address."
        }
        guard ["http", "https"].contains(scheme) else { return "Only http and https addresses can be opened (not \(scheme):)." }
        guard let host = components.host, !host.isEmpty else { return "The address has no host." }
        guard components.user == nil, components.password == nil else { return "Addresses containing a username or password are refused." }
        return nil
    }

    /// Why Halo refuses to type `text`, or nil when it may be offered for approval.
    /// Text that looks like a credential is never typed, even if requested.
    static func textRefusal(_ text: String) -> String? {
        if text.isEmpty { return "There is no text to type." }
        if text.utf16.count > BrowserBridgeLimits.maxTypedTextLength { return "Text is longer than 4,000 characters." }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return "Text with line breaks, tabs, or control characters is refused: it could submit a form. Submitting is a separate, later step."
        }
        let secretPatterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\bsk-[A-Za-z0-9_\-]{16,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
            #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
            #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\."#,
            #"\b(?=[A-Za-z0-9+/_\-]*[0-9])(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{40,}\b"#
        ]
        if secretPatterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) {
            return "The text looks like a password, key, or token; Halo never types secrets."
        }
        // Payment card numbers: 13–19 digits (spaces or dashes allowed) passing Luhn.
        if let regex = try? NSRegularExpression(pattern: #"(?:\d[ -]?){12,18}\d"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let digits = text[range].compactMap(\.wholeNumberValue)
                var sum = 0
                for (index, digit) in digits.reversed().enumerated() {
                    let value = index % 2 == 1 ? digit * 2 : digit
                    sum += value > 9 ? value - 9 : value
                }
                if (13...19).contains(digits.count), sum % 10 == 0 {
                    return "The text looks like a payment card number; Halo never types payment details."
                }
            }
        }
        return nil
    }

    /// One correlated bridge exchange for an authorized tab. Pending lifecycle
    /// events are applied first; the response is matched by request ID; any
    /// navigation, close, pause, revoke, or epoch change in flight fails closed.
    private func bridgeExchange(
        id: Int, key: AuthorizedTabKey, context: BrowserContext,
        server: BridgeIPCServer, validator: BridgeSessionValidator,
        requiredGeneration: UInt64? = nil, timeout: TimeInterval = 5, allowsNavigation: Bool = false,
        makeRequest: (TabGenerationIdentity, String, String) -> BridgeRequest
    ) async throws -> (BridgeResponse, TabGenerationIdentity, AuthorizedTabRecord) {
        guard !bridgeReadInFlight else {
            throw InteractionError("Another browser operation is already in progress.")
        }
        bridgeReadInFlight = true
        defer { bridgeReadInFlight = false }
        let nonce = server.sessionConfig.sessionNonce
        do {
            while await server.hasPendingMessage() {
                _ = try await applyBridgeMessage(try await server.receiveResponse(timeoutSeconds: 2), nonce: nonce, validator: validator)
            }
        } catch {
            throw InteractionError("The authenticated browser bridge failed closed: \(error.localizedDescription)")
        }
        guard !isPaused, let record = authorizedTabs[key] else {
            throw InteractionError("Tab \(id) is no longer authorized; the page navigated or closed.")
        }
        let generation = bridgeGenerations[key] ?? 1
        if let requiredGeneration, requiredGeneration != generation {
            throw InteractionError("The page changed after approval; nothing was done.")
        }
        let epoch = accessEpoch
        let browserIdent = BrowserIdentity(bundleID: context.bundleID, sessionID: context.sessionID, pid: context.pid)
        let tabIdent = TabGenerationIdentity(browser: browserIdent, tabID: id, documentGenerationID: generation, url: record.url, domain: record.domain)
        let reqID = BridgeSocketIO.generateRandomHex(byteCount: 8)
        let request = makeRequest(tabIdent, reqID, nonce)
        do {
            try await validator.authorizeTab(tabIdent)
            try await validator.validateRequest(request)
            try await server.sendRequest(request)
            var changedInFlight = false
            let deadline = Date().addingTimeInterval(timeout)
            var resp: BridgeResponse
            while true {
                resp = try await server.receiveResponse(timeoutSeconds: max(0.1, deadline.timeIntervalSinceNow))
                switch try await applyBridgeMessage(resp, nonce: nonce, validator: validator) {
                case .event(let affected):
                    if affected == key && !allowsNavigation { changedInFlight = true }
                    continue
                case .response where resp.requestID != reqID:
                    continue // Response to an earlier, abandoned request.
                case .response:
                    break
                }
                break
            }
            if changedInFlight {
                throw InteractionError("The browser tab changed while the operation was in flight.")
            }
            try await validator.validateResponse(resp)
            try Task.checkCancellation()
            // A requested navigation legitimately changes the record and epoch.
            guard !isPaused, allowsNavigation || (epoch == accessEpoch && authorizedTabs[key] == record) else {
                throw InteractionError("Browser tab access changed while the operation was in flight.")
            }
            guard resp.success else {
                if resp.error?.code == .hostNotGranted { throw SiteAccessWithheld() }
                let message = Self.plainBridgeError(resp.error?.message ?? "The browser bridge refused the operation.")
                // Pages re-render; a changed or replaced element is never acted on,
                // but a fresh read usually offers its current equivalent.
                if resp.error?.code == .elementChanged {
                    throw InteractionError(message + " Nothing was done. Read the tab again and use a current element id.")
                }
                throw InteractionError(message)
            }
            return (resp, tabIdent, record)
        } catch {
            if let interError = error as? InteractionError { throw interError }
            if error is SiteAccessWithheld { throw error }
            let plain = Self.plainBridgeError(error.localizedDescription)
            throw InteractionError(plain == error.localizedDescription
                ? "The browser connection stopped safely (failed closed); nothing was done: \(plain)" : plain)
        }
    }

    /// Bridge failures in words the user (and the model) can act on, never raw
    /// socket or debugger internals that invite guessing.
    static func plainBridgeError(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("deadline") || raw.localizedCaseInsensitiveContains("didn't respond in time") {
            return "The page didn't respond in time; nothing was done. Try again."
        }
        if raw.contains("Another debugger") {
            return "Another tool (such as Chrome DevTools) is controlling this tab, so nothing was done. Close it and try again."
        }
        return raw
    }

    /// Chrome withholds the extension's access to this site (user-restricted).
    struct SiteAccessWithheld: Error {}

    /// Observes through the bridge, or returns nil when Chrome withholds the
    /// extension's access to this site so the caller falls back to AppleScript.
    private func bridgeObservation(id: Int, key: AuthorizedTabKey, context: BrowserContext,
                                   server: BridgeIPCServer, validator: BridgeSessionValidator) async throws
        -> (BridgeResponse, TabGenerationIdentity, AuthorizedTabRecord)? {
        let origin = authorizedTabs[key].flatMap { Self.origin(of: $0.url) } ?? ""
        do {
            let result = try await bridgeExchange(id: id, key: key, context: context, server: server, validator: validator) {
                BridgeRequest(requestID: $1, sessionNonce: $2, type: .observeTab, targetTab: $0)
            }
            siteAccessWithheld.remove(origin)
            return result
        } catch is SiteAccessWithheld {
            siteAccessWithheld.insert(origin)
            bridgeElements.removeValue(forKey: key)
            return nil
        }
    }

    /// Re-observes the tab and resolves an element for an approval preview.
    public func describeElementTarget(tabID: Int, elementID: String, action: BrowserElementAction,
                                      browserAppID: String? = nil) async throws -> BrowserElementTarget {
        guard bridgeServer != nil else {
            throw InteractionError("Browser actions require the Halo browser extension connection (Settings → Mac Access → Browser bridge).")
        }
        try requireBridgeCoverage(tabID: tabID, browserAppID: browserAppID)
        let content = try await readTab(id: tabID, browserAppID: browserAppID)
        try requireSiteAccess(content.url)
        let context = try browserContext(browserAppID)
        let key = tabKey(tabID, context: context)
        guard let observed = bridgeElements[key], let element = observed.elements[elementID] else {
            throw InteractionError("Element \(elementID) is not on the current page. Read the tab again and use a current element ID.")
        }
        switch action {
        case .select where !Self.isSelectable(element):
            throw InteractionError("Only enabled single-choice dropdowns can be changed. Multi-select, disabled, and payment or credential dropdowns are blocked.")
        case .scroll where !Self.isScrollable(element):
            throw InteractionError("That element is not a scrollable region. Omit element_id to scroll the page.")
        case .click where element.blockedReason != nil:
            throw InteractionError("Blocked: \(Self.blockedReasonText(element.blockedReason!)). Halo does not perform this kind of action yet.")
        case .click where !Self.isClickable(element, pageURL: content.url):
            throw InteractionError("This element cannot be clicked. Plain buttons, ordinary same-site form submissions, and same-tab links can; protected, disabled, and hidden controls cannot.")
        case .type where !Self.isTypable(element):
            throw InteractionError("Only enabled plain text fields can be typed into. Password, one-time-code, payment, read-only, and disabled fields are blocked.")
        default:
            break
        }
        var target = BrowserElementTarget(tabID: tabID, title: content.title, url: content.url, domain: content.domain,
                                          elementID: elementID, tagName: element.tagName, role: element.role,
                                          label: element.label, key: key, generation: observed.generation)
        target.options = element.options ?? []
        if action == .click {
            target.clickKind = Self.clickKind(element, pageURL: content.url)
            target.destination = element.destinationURL
            target.formFields = element.formFields ?? []
        }
        return target
    }

    /// Re-observes the tab and describes the whole page as an action target
    /// (page scroll and navigation).
    public func describePageTarget(tabID: Int, browserAppID: String? = nil) async throws -> BrowserElementTarget {
        guard bridgeServer != nil else {
            throw InteractionError("Browser actions require the Halo browser extension connection (Settings → Mac Access → Browser bridge).")
        }
        try requireBridgeCoverage(tabID: tabID, browserAppID: browserAppID)
        let content = try await readTab(id: tabID, browserAppID: browserAppID)
        try requireSiteAccess(content.url)
        let context = try browserContext(browserAppID)
        let key = tabKey(tabID, context: context)
        guard let observed = bridgeElements[key] else { throw InteractionError("Tab \(tabID) has no current observation.") }
        return BrowserElementTarget(tabID: tabID, title: content.title, url: content.url, domain: content.domain,
                                    elementID: BrowserElementTarget.pageReference, tagName: "html", role: "page",
                                    label: content.title, key: key, generation: observed.generation)
    }

    /// Performs one approved click. The page, element, and its position are
    /// re-verified by the extension; nothing is clicked if any of them changed.
    public func click(_ target: BrowserElementTarget) async throws -> BrowserClickResult {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        guard let server = bridgeServer, let validator = bridgeValidator, await server.isConnected else {
            throw InteractionError("The Halo browser extension disconnected; nothing was clicked.")
        }
        let context = try browserContext(target.key.browserBundleID)
        guard context.sessionID == target.key.browserSessionID else {
            throw InteractionError("The browser restarted after approval; nothing was clicked.")
        }
        let kind = target.clickKind ?? .button
        let fingerprint = BridgeElementFingerprint(tagName: target.tagName, role: target.role, label: target.label,
                                                   kind: kind.rawValue, destination: kind == .button ? nil : target.destination)
        // Any click may navigate (links and submissions always do); its result
        // still counts, and the navigation is applied like any other.
        TimingLog.shared.mark("  click: sent to extension")
        defer { TimingLog.shared.mark("  click: finished (incl. page read after)") }
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation,
                                                    timeout: 10, allowsNavigation: true) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .clickElement, targetTab: $0,
                          elementID: target.elementID, expectedElement: fingerprint)
        }
        guard let action = resp.actionResult, action.elementID == target.elementID else {
            throw InteractionError("The browser bridge returned no click result.")
        }
        TimingLog.shared.mark("  click: extension answered")
        await applyPendingBridgeMessages()
        let stillAuthorized = authorizedTabs[target.key] != nil
        let after = stillAuthorized ? try? await readTab(id: target.tabID, browserAppID: target.key.browserBundleID) : nil
        var result = BrowserClickResult(verified: action.performed, after: after)
        result.stillAuthorized = stillAuthorized
        return result
    }

    /// Applies lifecycle events that arrived just after an action's result.
    private func applyPendingBridgeMessages() async {
        guard let server = bridgeServer, let validator = bridgeValidator else { return }
        while await server.hasPendingMessage() {
            guard let message = try? await server.receiveResponse(timeoutSeconds: 2) else { break }
            _ = try? await applyBridgeMessage(message, nonce: server.sessionConfig.sessionNonce, validator: validator)
        }
    }

    /// Text Halo itself typed into `elementID` in the target's document, if any.
    public func typedText(in target: BrowserElementTarget, elementID: String) -> String? {
        guard let typed = typedTexts[target.key], typed.generation == target.generation else { return nil }
        return typed.texts[elementID]
    }

    /// Replaces one approved field's contents with approved text. The extension
    /// re-verifies the page and field; only whether the field now holds exactly
    /// this text is reported back, never the field's value.
    public func type(_ target: BrowserElementTarget, text: String) async throws -> BrowserClickResult {
        if let refusal = Self.textRefusal(text) { throw InteractionError(refusal) }
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        guard let server = bridgeServer, let validator = bridgeValidator, await server.isConnected else {
            throw InteractionError("The Halo browser extension disconnected; nothing was typed.")
        }
        let context = try browserContext(target.key.browserBundleID)
        guard context.sessionID == target.key.browserSessionID else {
            throw InteractionError("The browser restarted after approval; nothing was typed.")
        }
        let fingerprint = BridgeElementFingerprint(tagName: target.tagName, role: target.role, label: target.label)
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation, timeout: 10) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .typeText, targetTab: $0,
                          elementID: target.elementID, expectedElement: fingerprint, text: text)
        }
        guard let action = resp.actionResult, action.elementID == target.elementID else {
            throw InteractionError("The browser bridge returned no typing result.")
        }
        if action.performed {
            var typed = typedTexts[target.key].flatMap { $0.generation == target.generation ? $0 : nil }
                ?? (generation: target.generation, texts: [:])
            typed.texts[target.elementID] = text
            typedTexts[target.key] = typed
        }
        let after = try? await readTab(id: target.tabID, browserAppID: target.key.browserBundleID)
        return BrowserClickResult(verified: action.performed, after: after)
    }

    /// Common preconditions for an approved action on `target`.
    private func actionChannel(_ target: BrowserElementTarget, verb: String) async throws
        -> (BridgeIPCServer, BridgeSessionValidator, BrowserContext) {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        guard let server = bridgeServer, let validator = bridgeValidator, await server.isConnected else {
            throw InteractionError("The Halo browser extension disconnected; nothing was \(verb).")
        }
        let context = try browserContext(target.key.browserBundleID)
        guard context.sessionID == target.key.browserSessionID else {
            throw InteractionError("The browser restarted after approval; nothing was \(verb).")
        }
        return (server, validator, context)
    }

    /// Chooses one approved option in an approved dropdown.
    public func select(_ target: BrowserElementTarget, option: String) async throws -> BrowserClickResult {
        guard target.options.contains(option) else {
            throw InteractionError("“\(option)” is not one of the dropdown's options.")
        }
        let (server, validator, context) = try await actionChannel(target, verb: "selected")
        let fingerprint = BridgeElementFingerprint(tagName: target.tagName, role: target.role, label: target.label)
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .selectOption, targetTab: $0,
                          elementID: target.elementID, expectedElement: fingerprint, option: option)
        }
        guard let action = resp.actionResult, action.elementID == target.elementID else {
            throw InteractionError("The browser bridge returned no selection result.")
        }
        let after = try? await readTab(id: target.tabID, browserAppID: target.key.browserBundleID)
        return BrowserClickResult(verified: action.performed, after: after)
    }

    /// Scrolls the page or one approved scrollable region with a trusted wheel event.
    public func scroll(_ target: BrowserElementTarget, direction: BridgeScrollDirection, amount: Int) async throws -> BrowserClickResult {
        guard (1...20).contains(amount) else { throw InteractionError("Scroll amount must be 1–20 steps.") }
        let (server, validator, context) = try await actionChannel(target, verb: "scrolled")
        let fingerprint = target.isPage ? nil : BridgeElementFingerprint(tagName: target.tagName, role: target.role, label: target.label)
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation, timeout: 10) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .scrollTab, targetTab: $0,
                          elementID: target.isPage ? nil : target.elementID, expectedElement: fingerprint,
                          scroll: BridgeScroll(direction: direction, amount: amount))
        }
        guard let action = resp.actionResult, action.elementID == target.elementID else {
            throw InteractionError("The browser bridge returned no scroll result.")
        }
        return BrowserClickResult(verified: action.performed, after: nil)
    }

    /// Controls the page's main video or audio. `verified` means the media
    /// state now shows the command took effect (playing, paused, muted…).
    public func media(_ target: BrowserElementTarget, command: BridgeMediaCommand, value: Double? = nil) async throws
        -> (verified: Bool, state: BridgeMediaState?) {
        let (server, validator, context) = try await actionChannel(target, verb: "changed")
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation, timeout: 10) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .mediaControl, targetTab: $0,
                          media: BridgeMedia(command: command, value: value))
        }
        guard let action = resp.actionResult else { throw InteractionError("The browser bridge returned no media result.") }
        return (action.performed, action.media)
    }

    /// Navigates the tab to one approved address. Old element references die
    /// with the old document; leaving the authorized domain ends access.
    public func navigate(_ target: BrowserElementTarget, to url: String) async throws -> BrowserNavigationResult {
        if let refusal = Self.navigationRefusal(url) { throw InteractionError(refusal) }
        let (server, validator, context) = try await actionChannel(target, verb: "opened")
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation,
                                                    timeout: 10, allowsNavigation: true) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .navigateTab, targetTab: $0, url: url)
        }
        guard let action = resp.actionResult, action.performed else {
            throw InteractionError("The browser did not start loading the address.")
        }
        // Apply the navigation event if it arrived just after the result.
        if let server = bridgeServer, let validator = bridgeValidator {
            while await server.hasPendingMessage() {
                guard let message = try? await server.receiveResponse(timeoutSeconds: 2) else { break }
                _ = try? await applyBridgeMessage(message, nonce: server.sessionConfig.sessionNonce, validator: validator)
            }
        }
        bridgeElements.removeValue(forKey: target.key)
        let record = authorizedTabs[target.key]
        return BrowserNavigationResult(url: record?.url ?? url, stillAuthorized: record != nil)
    }

    public func readTab(id: Int, browserAppID: String? = nil) async throws -> BrowserTabContent {
        guard !isPaused else { throw InteractionError("Browser tab access is currently paused.") }
        let context = try browserContext(browserAppID)
        let key = tabKey(id, context: context)
        guard let record = authorizedTabs[key] else {
            throw InteractionError("Tab \(id) is not authorized for this browser session.")
        }
        let epoch = accessEpoch

        // 1. If an authenticated Native Messaging bridge is connected, route observation through the bridge:
        // Only sites the extension can reach go through the bridge; others keep
        // the AppleScript read path, so enabling the bridge never breaks reading.
        if let server = bridgeServer, let validator = bridgeValidator, Self.bridgeCovers(record.url), await server.isConnected,
           let (resp, tabIdent, record) = try await bridgeObservation(id: id, key: key, context: context, server: server, validator: validator) {
            guard let obs = resp.observation, obs.tab == tabIdent else {
                throw InteractionError(resp.error?.message ?? "Bridge observation failed.")
            }
            guard obs.tab.domain.lowercased() == record.domain.lowercased() else {
                authorizedTabs.removeValue(forKey: key)
                throw InteractionError("Tab \(id) navigated from '\(record.domain)' to '\(obs.tab.domain)'; authorization was revoked.")
            }
            // Observations are capped and on-screen-first, so an element seen
            // earlier in this document may be missing from the latest listing
            // (e.g. a suggestion dropdown opened). Keep what was seen in the same
            // document; the extension re-verifies any element before acting.
            let latest = Dictionary(obs.elements.map { ($0.elementID, $0) }, uniquingKeysWith: { first, _ in first })
            if let previous = bridgeElements[key], previous.generation == obs.tab.documentGenerationID, previous.elements.count < 2_000 {
                bridgeElements[key] = (obs.tab.documentGenerationID, previous.elements.merging(latest) { _, new in new })
            } else {
                bridgeElements[key] = (obs.tab.documentGenerationID, latest)
            }
            // Prefer the page's readable text; element lines are the fallback.
            let contentText = obs.text.flatMap { $0.isEmpty ? nil : $0 } ?? obs.elements.map { el in
                el.isProtected ? "[\(el.role): (protected)]" : "\(el.role): \(el.label)"
            }.joined(separator: "\n")
            var content = BrowserTabContent(
                id: id,
                title: String(obs.title.prefix(200)),
                url: obs.tab.url,
                domain: obs.tab.domain,
                content: contentText,
                truncated: contentText.utf16.count >= 16000
            )
            content.elements = obs.elements.map {
                var element = BrowserTabElement(id: $0.elementID, role: $0.role, tagName: $0.tagName,
                                                label: $0.isProtected ? "(protected)" : String($0.label.prefix(200)),
                                                clickable: Self.isClickable($0, pageURL: obs.tab.url), typable: Self.isTypable($0))
                element.selectable = Self.isSelectable($0)
                element.scrollable = Self.isScrollable($0)
                element.clickKind = Self.clickKind($0, pageURL: obs.tab.url)?.rawValue
                element.blocked = $0.blockedReason.map(Self.blockedReasonText)
                if element.selectable { element.options = $0.options ?? [] }
                return element
            }
            return content
        }

        // 2. Default read-only AppleScript path:
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
