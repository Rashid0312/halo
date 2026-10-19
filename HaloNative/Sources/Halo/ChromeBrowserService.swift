import Foundation
import AppKit
import HaloBridge

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
    let key: AuthorizedTabKey
    let generation: UInt64

    /// Reference used for actions on the whole page rather than one element.
    static let pageReference = "el_page"
    var isPage: Bool { elementID == Self.pageReference }
}

public struct BrowserClickResult: Sendable {
    /// True when the extension confirmed the genuine click reached the element.
    public let verified: Bool
    /// Fresh observation after the click, when the page is still readable.
    public let after: BrowserTabContent?
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
    private var bridgeServer: BridgeIPCServer? = nil
    private var bridgeValidator: BridgeSessionValidator? = nil
    private var bridgeGenerations: [AuthorizedTabKey: UInt64] = [:]
    private var bridgeReadInFlight = false
    /// Latest bridge observation per tab, bound to the document generation it came from.
    private var bridgeElements: [AuthorizedTabKey: (generation: UInt64, elements: [String: ObservedDOMElement])] = [:]

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

    public func revoke(tabID: Int, browserAppID: String? = nil) async {
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
    static func isClickable(_ element: ObservedDOMElement) -> Bool {
        element.isActionable == true && element.isEnabled && !element.isProtected &&
            (element.tagName == "button" || element.role == "button")
    }

    /// Phase 5B.2 policy, enforced by Halo independently of the extension's flag:
    /// enabled, unprotected plain text inputs and textareas only.
    static func isTypable(_ element: ObservedDOMElement) -> Bool {
        element.isEditable == true && element.isEnabled && !element.isProtected &&
            ["input", "textarea"].contains(element.tagName)
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
                throw InteractionError(resp.error?.message ?? "The browser bridge refused the operation.")
            }
            return (resp, tabIdent, record)
        } catch {
            if let interError = error as? InteractionError { throw interError }
            throw InteractionError("The authenticated browser bridge failed closed: \(error.localizedDescription)")
        }
    }

    /// Re-observes the tab and resolves an element for an approval preview.
    public func describeElementTarget(tabID: Int, elementID: String, action: BrowserElementAction,
                                      browserAppID: String? = nil) async throws -> BrowserElementTarget {
        guard bridgeServer != nil else {
            throw InteractionError("Browser actions require the Halo browser extension connection (Settings → Mac Access → Browser bridge).")
        }
        let content = try await readTab(id: tabID, browserAppID: browserAppID)
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
        case .click where !Self.isClickable(element):
            throw InteractionError("Only plain, enabled buttons can be clicked. Links, form submission, and protected or disabled controls are blocked.")
        case .type where !Self.isTypable(element):
            throw InteractionError("Only enabled plain text fields can be typed into. Password, one-time-code, payment, read-only, and disabled fields are blocked.")
        default:
            break
        }
        var target = BrowserElementTarget(tabID: tabID, title: content.title, url: content.url, domain: content.domain,
                                          elementID: elementID, tagName: element.tagName, role: element.role,
                                          label: element.label, key: key, generation: observed.generation)
        target.options = element.options ?? []
        return target
    }

    /// Re-observes the tab and describes the whole page as an action target
    /// (page scroll and navigation).
    public func describePageTarget(tabID: Int, browserAppID: String? = nil) async throws -> BrowserElementTarget {
        guard bridgeServer != nil else {
            throw InteractionError("Browser actions require the Halo browser extension connection (Settings → Mac Access → Browser bridge).")
        }
        let content = try await readTab(id: tabID, browserAppID: browserAppID)
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
        let fingerprint = BridgeElementFingerprint(tagName: target.tagName, role: target.role, label: target.label)
        let (resp, _, _) = try await bridgeExchange(id: target.tabID, key: target.key, context: context, server: server,
                                                    validator: validator, requiredGeneration: target.generation, timeout: 10) {
            BridgeRequest(requestID: $1, sessionNonce: $2, type: .clickElement, targetTab: $0,
                          elementID: target.elementID, expectedElement: fingerprint)
        }
        guard let action = resp.actionResult, action.elementID == target.elementID else {
            throw InteractionError("The browser bridge returned no click result.")
        }
        let after = try? await readTab(id: target.tabID, browserAppID: target.key.browserBundleID)
        return BrowserClickResult(verified: action.performed, after: after)
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
        if let server = bridgeServer, let validator = bridgeValidator, await server.isConnected {
            let (resp, tabIdent, record) = try await bridgeExchange(id: id, key: key, context: context, server: server, validator: validator) {
                BridgeRequest(requestID: $1, sessionNonce: $2, type: .observeTab, targetTab: $0)
            }
            guard let obs = resp.observation, obs.tab == tabIdent else {
                throw InteractionError(resp.error?.message ?? "Bridge observation failed.")
            }
            guard obs.tab.domain.lowercased() == record.domain.lowercased() else {
                authorizedTabs.removeValue(forKey: key)
                throw InteractionError("Tab \(id) navigated from '\(record.domain)' to '\(obs.tab.domain)'; authorization was revoked.")
            }
            bridgeElements[key] = (obs.tab.documentGenerationID, Dictionary(obs.elements.map { ($0.elementID, $0) }, uniquingKeysWith: { first, _ in first }))
            let contentText = obs.elements.map { el in
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
                                                clickable: Self.isClickable($0), typable: Self.isTypable($0))
                element.selectable = Self.isSelectable($0)
                element.scrollable = Self.isScrollable($0)
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
