import AppKit
import Foundation
import HaloBridge

/// Opt-in check against the user's real Google Chrome with the development
/// extension loaded unpacked. Uses production code end to end: the system
/// browser runtime (real AppleScript tab IDs), the bridge controller with the
/// host registered only in Chrome's folder, and the model-facing tools with
/// approvals answered by the check (each preview is printed). It acts only in
/// tabs it opens, and closes them and removes the registration afterwards.
extension NativeChecks {
    @MainActor
    static func realChromeCheck() async throws {
        print("--- Real Chrome check (your browser, real websites) ---")
        let chromeID = "com.google.Chrome"
        let chromeHosts = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        let manifestFile = chromeHosts.appendingPathComponent("\(BrowserBridgeController.hostName).json")
        let defaultsSuite = "app.halo.real-chrome-check.\(getpid())"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let service = ChromeBrowserService()
        let controller = BrowserBridgeController(service: service, helperURL: try locateHelperBinary(),
                                                 manifestDirectories: { [chromeHosts] }, defaults: defaults)
        let tools = MacTools(catalog: AppCatalog(), browserService: service)
        var openedTabs: [Int] = []

        tools.showApproval = { [weak tools] in
            guard let tools, let approval = tools.approval else { return }
            print("  APPROVAL ▸ \(approval.title) [\(approval.path)]\n    " + approval.preview.replacingOccurrences(of: "\n", with: "\n    "))
            tools.resolve(id: approval.id, allow: true)
        }
        func run(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            var args = args
            args["browser_app_id"] = chromeID
            let data = try JSONSerialization.data(withJSONObject: args)
            let raw = try await tools.execute(name: name, arguments: String(decoding: data, as: UTF8.self))
            return try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        }
        func waitFor(_ what: String, timeout: TimeInterval, _ condition: () async -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(250))
            }
            throw Failure("Timed out after \(Int(timeout))s waiting for \(what).")
        }
        func isConnected() -> Bool { if case .connected = controller.status { return true } else { return false } }
        func elements(_ tabID: Int) async throws -> [[String: Any]] {
            let read = try await run("read_browser_tab", ["tab_id": tabID])
            guard read["ok"] as? Bool == true else { throw Failure("read_browser_tab failed: \(read)") }
            return parsePage(read["page"] as? String ?? "")
        }
        /// Opens a tab, waits for it to load, and authorizes it through the tool.
        func openAndAuthorize(_ url: String, host: String) async throws -> (id: Int, url: String) {
            let id = try await service.openTab(url: url, browserAppID: chromeID)
            openedTabs.append(id)
            var loaded: BrowserTab?
            try await waitFor("\(host) to load", timeout: 30) {
                loaded = try? await service.listTabs(browserAppID: chromeID).first { $0.id == id && !$0.title.isEmpty && $0.url.hasPrefix("http") }
                return loaded != nil
            }
            let authorized = try await run("authorize_browser_tab", ["tab_id": id])
            guard authorized["ok"] as? Bool == true else { throw Failure("Authorizing the \(host) tab failed: \(authorized)") }
            return (id, loaded?.url ?? url)
        }
        /// Clicks the element `pick` selects; if the page re-rendered it before
        /// the click (refused, nothing done), re-reads and retries once, as the
        /// model would. Each attempt is a fresh approval.
        func clickFresh(_ tabID: Int, _ pick: ([[String: Any]]) -> [String: Any]?) async throws -> [String: Any] {
            for attempt in 1...2 {
                guard let target = pick(try await elements(tabID)), let id = target["id"] as? String else {
                    throw Failure("The element to click is not on the page.")
                }
                let result = try await run("click_browser_element", ["tab_id": tabID, "element_id": id])
                if result["ok"] as? Bool == true || attempt == 2 { return result }
                guard (result["error"] as? String)?.contains("Read the tab again") == true else { return result }
                print("INFO: The page re-rendered “\(target["label"] ?? "")” before the click; nothing was clicked. Re-reading and retrying.")
                try await Task.sleep(for: .milliseconds(500))
            }
            return [:]
        }
        /// Types into the field `pick` selects; if the page swapped the field
        /// while typing (unconfirmed or refused), re-reads and types again.
        /// Typing replaces the field's contents, so a retry is safe.
        func typeFresh(_ tabID: Int, _ text: String, _ pick: ([[String: Any]]) -> [String: Any]?) async throws -> [String: Any] {
            for attempt in 1...2 {
                guard let field = pick(try await elements(tabID)), let id = field["id"] as? String else {
                    throw Failure("The field to type into is not on the page.")
                }
                let result = try await run("type_in_browser_field", ["tab_id": tabID, "element_id": id, "text": text])
                if result["verified"] as? Bool == true || attempt == 2 { return result }
                print("INFO: The page replaced “\(field["label"] ?? "")” while typing; the text could not be confirmed. Re-reading and typing again.")
                try await Task.sleep(for: .milliseconds(500))
            }
            return [:]
        }
        func currentURL(_ tabID: Int) async -> String {
            (try? await service.readTab(id: tabID, browserAppID: chromeID).url) ?? ""
        }

        /// Closes the check's own tabs and removes the registration. Awaited on
        /// both success and failure, before the process can exit.
        func cleanUp() async {
            for tab in openedTabs { try? await service.closeTab(id: tab, browserAppID: chromeID) }
            openedTabs = []
            controller.enabled = false
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }

        do {
        // Bridge: register the host for Chrome and wait for the extension.
        _ = try await service.resolveBrowserAppName(chromeID)
        controller.enabled = true
        guard controller.status == .waiting, FileManager.default.fileExists(atPath: manifestFile.path) else {
            throw Failure("Could not register the native host for Chrome: \(controller.status.summary) If the Halo app is running with Browser bridge on, quit it or turn the bridge off first.")
        }

        // 1. Wikipedia: the full flow.
        let wiki = try await openAndAuthorize("https://en.wikipedia.org/wiki/Main_Page", host: "Wikipedia")
        try await waitFor("the Chrome extension to connect (it retries with backoff)", timeout: 60) { isConnected() }
        // Every web tab must carry the same ID and address in AppleScript and in
        // the extension's announcement (tab titles and addresses are not printed).
        let appleScriptTabs = try await service.listTabs(browserAppID: chromeID)
        let announcedByID = Dictionary(controller.announcements.map { ($0.tabID, $0.url) }, uniquingKeysWith: { first, _ in first })
        let compared = appleScriptTabs.filter { announcedByID[$0.id] != nil }
        let mismatched = compared.filter { announcedByID[$0.id] != $0.url }
        // Halo's listing stops at 50 tabs; only then can every announced tab be expected in it.
        let unknownToAppleScript = appleScriptTabs.count < 50 ? Set(announcedByID.keys).subtracting(appleScriptTabs.map(\.id)) : []
        guard !compared.isEmpty, mismatched.isEmpty, unknownToAppleScript.isEmpty else {
            throw Failure("Tab IDs disagree: \(compared.count) compared, \(mismatched.count) with different addresses, \(unknownToAppleScript.count) unknown to AppleScript.")
        }
        print("PASS: Tab IDs match: \(compared.count) web tabs have the same ID and address in AppleScript and in the extension.")
        var wikiElements: [[String: Any]] = []
        try await waitFor("a bridge observation of Wikipedia", timeout: 20) {
            wikiElements = (try? await elements(wiki.id)) ?? []
            return !wikiElements.isEmpty
        }
        print("PASS: Real site read through the bridge: Wikipedia returned \(wikiElements.count) element references (the bridge resolved Halo's AppleScript tab ID, so the IDs agree).")

        let scrolled = try await run("scroll_browser_tab", ["tab_id": wiki.id, "direction": "down", "amount": 3])
        guard scrolled["verified"] as? Bool == true else { throw Failure("Scrolling Wikipedia failed: \(scrolled)") }
        _ = try await run("scroll_browser_tab", ["tab_id": wiki.id, "direction": "up", "amount": 5])
        print("PASS: Scrolled Wikipedia with a genuine wheel event (verified), then back up.")

        let isSearchField: ([String: Any]) -> Bool = { $0["typable"] as? Bool == true && ($0["label"] as? String ?? "").localizedCaseInsensitiveContains("search") }
        wikiElements = try await elements(wiki.id)
        if let field = wikiElements.first(where: isSearchField) {
            let typed = try await typeFresh(wiki.id, "Ada Lovelace") { $0.first(where: isSearchField) }
            guard typed["verified"] as? Bool == true else { throw Failure("Typing into Wikipedia search failed: \(typed)") }
            print("PASS: Typed into Wikipedia's search field “\(field["label"] ?? "")” (verified without reading the field).")
            let submitted = try await clickFresh(wiki.id) { $0.first { $0["click_kind"] as? String == "submit" } }
            guard submitted["ok"] as? Bool == true else { throw Failure("Submitting Wikipedia search failed: \(submitted)") }
            try await waitFor("search results", timeout: 20) { let now = await currentURL(wiki.id); return now.contains("Ada_Lovelace") || now.contains("search=") }
            let resultURL = await currentURL(wiki.id)
            print("PASS: Submitted the search (\(submitted["verified"] as? Bool == true ? "submit verified" : "submit sent")); Wikipedia is now at \(resultURL).")
        } else {
            print("INFO: Wikipedia's search box is not on screen at this window width; opening the article directly.")
            _ = try await run("navigate_browser_tab", ["tab_id": wiki.id, "url": "https://en.wikipedia.org/wiki/Ada_Lovelace"])
        }

        try await waitFor("the article", timeout: 20) { !((try? await elements(wiki.id)) ?? []).isEmpty }
        wikiElements = try await elements(wiki.id)
        let articleLink = wikiElements.first { element in
            guard element["click_kind"] as? String == "link", let label = element["label"] as? String else { return false }
            return label == "Charles Babbage"
        } ?? wikiElements.first { element in
            element["click_kind"] as? String == "link" && (element["label"] as? String ?? "").count > 3
        }
        guard let link = articleLink, let linkID = link["id"] as? String else { throw Failure("No followable link found on the article.") }
        let before = await currentURL(wiki.id)
        let followed = try await run("click_browser_element", ["tab_id": wiki.id, "element_id": linkID])
        guard followed["ok"] as? Bool == true else { throw Failure("Following a Wikipedia link failed: \(followed)") }
        try await waitFor("the linked page", timeout: 20) { let now = await currentURL(wiki.id); return !now.isEmpty && now != before }
        let linkedURL = await currentURL(wiki.id)
        print("PASS: Followed the link “\(link["label"] ?? "")” with a genuine click; now at \(linkedURL).")

        // 2. YouTube: best effort, never past a consent wall.
        let youtube = try await openAndAuthorize("https://www.youtube.com/", host: "YouTube")
        if !youtube.url.contains("www.youtube.com") {
            print("INFO: YouTube redirected to \(URLComponents(string: youtube.url)?.host ?? youtube.url) (likely a consent page). Halo does not accept cookies on your behalf; stopping YouTube here.")
        } else {
            var ytElements: [[String: Any]] = []
            try await waitFor("a bridge observation of YouTube", timeout: 20) {
                ytElements = (try? await elements(youtube.id)) ?? []
                return !ytElements.isEmpty
            }
            let clickable = ytElements.filter { $0["clickable"] as? Bool == true }.count
            let blocked = ytElements.filter { $0["blocked"] != nil }.count
            print("PASS: YouTube read through the bridge: \(ytElements.count) elements (\(clickable) clickable, \(blocked) blocked as sensitive).")
            let ytScroll = try await run("scroll_browser_tab", ["tab_id": youtube.id, "direction": "down", "amount": 3])
            print(ytScroll["verified"] as? Bool == true ? "PASS: Scrolled YouTube (verified)." : "INFO: YouTube scroll not confirmed: \(ytScroll["summary"] ?? ytScroll["error"] ?? "")")
            _ = try await run("scroll_browser_tab", ["tab_id": youtube.id, "direction": "up", "amount": 5])
            ytElements = try await elements(youtube.id)
            if ytElements.contains(where: isSearchField) {
                let typed = try await typeFresh(youtube.id, "lofi hip hop") { $0.first(where: isSearchField) }
                print(typed["verified"] as? Bool == true ? "PASS: Typed into YouTube's search field (verified)." : "INFO: YouTube typing not confirmed: \(typed)")
                ytElements = try await elements(youtube.id)
                // YouTube's search button is scripted (not a form submit): accept any clickable "Search".
                let pickSearch: ([[String: Any]]) -> [String: Any]? = { elements in
                    elements.first(where: { $0["click_kind"] as? String == "submit" })
                        ?? elements.first(where: { $0["clickable"] as? Bool == true && ($0["label"] as? String) == "Search" })
                }
                if pickSearch(ytElements) != nil {
                    let searched = try await clickFresh(youtube.id, pickSearch)
                    try? await waitFor("YouTube results", timeout: 20) { await currentURL(youtube.id).contains("/results") }
                    let now = await currentURL(youtube.id)
                    print(now.contains("/results") ? "PASS: YouTube search submitted; now at \(now)."
                          : "INFO: YouTube search click returned \(searched["summary"] ?? searched["error"] ?? "") but the page is at \(now).")
                } else {
                    let candidates = ytElements.filter { ($0["label"] as? String ?? "").localizedCaseInsensitiveContains("search") }
                    print("INFO: YouTube's search button is not an ordinary form submit; search-related elements: \(candidates.prefix(5).map { "\($0["label"] ?? "") [\($0["clickable"] as? Bool == true ? "clickable" : ($0["blocked"] as? String ?? "not clickable"))]" })")
                }
            } else {
                print("INFO: No typable search field found on YouTube. Labels on screen: \(ytElements.prefix(12).compactMap { $0["label"] as? String })")
            }
        }

        } catch {
            await cleanUp()
            throw error
        }
        // Cleanup is verified, not assumed.
        await cleanUp()
        guard !FileManager.default.fileExists(atPath: manifestFile.path) else { throw Failure("The native host registration was not removed.") }
        print("PASS: Cleanup: opened tabs closed, native host registration removed from Chrome.")
    }
}

extension NativeChecks {
    /// Read-only latency breakdown of the browser tools against the user's
    /// Chrome. Prints durations and counts only, never tab titles or addresses.
    @MainActor
    static func timeBrowserTools() async throws {
        func ms(_ start: ContinuousClock.Instant) -> String {
            let d = start.duration(to: .now)
            return String(format: "%.0f ms", Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
        }
        let runtime = SystemBrowserRuntime()
        let service = ChromeBrowserService()
        let tools = MacTools(catalog: AppCatalog(), browserService: service)
        for run in 1...3 {
            var t = ContinuousClock.now
            _ = try runtime.resolveBrowserContext("com.google.Chrome")
            let resolve = ms(t)
            t = .now
            let raw = try await runtime.runAppleScript("tell application \"Google Chrome\" to return count of (tabs of every window)")
            let trivialScript = ms(t)
            t = .now
            let tabs = try await service.listTabs(browserAppID: "com.google.Chrome")
            let list = ms(t)
            t = .now
            let tool = try await tools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false,"browser_app_id":"com.google.Chrome"}"#)
            let toolTime = ms(t)
            print("run \(run): resolve \(resolve) · trivial AppleScript \(trivialScript) (\(raw.count > 0 ? "ok" : "empty")) · listTabs \(list) for \(tabs.count) tabs · list_browser_tabs tool \(toolTime) (\(tool.count) bytes)")
        }
    }
}
