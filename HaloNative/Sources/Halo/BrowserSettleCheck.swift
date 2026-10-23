import AppKit
import Foundation
import HaloBridge

/// Timing and behaviour of the observation after a browser action, through the
/// model-facing tools, in a disposable Chromium profile: the local settle
/// fixture, then one real site (Wikipedia). Prints, per action, how long the
/// tool took and whether its result already showed the change.
extension NativeChecks {
    @MainActor
    static func browserSettleCheck(helperBinaryURL: URL) async throws {
        print("--- Browser settle and find check (disposable Chromium) ---")
        await reapOrphanedTestBrowsers()
        let browserURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
            .appendingPathComponent(".local-tools/chromium/chrome-mac/Chromium.app/Contents/MacOS/Chromium")
        guard FileManager.default.isExecutableFile(atPath: browserURL.path) else {
            throw Failure("Needs the unbranded Chromium build in .local-tools/chromium.")
        }
        let fixture = try DisposableTabServer()
        defer { fixture.stop() }
        let base = "http://127.0.0.1:\(fixture.port)"
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("halo-bridge-live-settle-\(UUID().uuidString)", isDirectory: true)
        let manifestDir = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let extPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/BrowserBridgeExtension").path
        let defaultsSuite = "app.halo.bridge-settle-check.\(getpid())"
        let runtime = AnnouncedTabsRuntime()
        let service = ChromeBrowserService(runtime: runtime)
        let controller = BrowserBridgeController(service: service, helperURL: helperBinaryURL,
                                                 manifestDirectories: { [manifestDir] in [manifestDir] },
                                                 defaults: UserDefaults(suiteName: defaultsSuite)!)
        let browser = Process()
        browser.executableURL = browserURL
        browser.arguments = ["--user-data-dir=\(profile.path)", "--remote-debugging-port=0", "--no-first-run",
                             "--no-default-browser-check", "--window-size=1200,900"]
            // Headless by default: a window covered by others draws no frames,
            // and Chrome then stalls trusted input that needs one (see report).
            + (ProcessInfo.processInfo.environment["HALO_SETTLE_WINDOWED"] == nil ? ["--headless=new"] : [])
            + [
                             "--disable-extensions-except=\(extPath)", "--load-extension=\(extPath)", base + "/settle"]
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        defer {
            controller.shutdownForTermination()
            terminateProcessBounded(browser)
            try? FileManager.default.removeItem(at: profile)
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }
        controller.enabled = true
        try browser.run()
        runtime.setBrowser(pid: browser.processIdentifier)
        _ = try await waitUntil("extension handshake", timeout: 20) {
            if case .connected = controller.status { return true } else { return false }
        }
        let devtools = try await DevToolsClient.attach(profile: profile)
        guard let tabID = controller.announcements.first(where: { $0.url.hasPrefix(base + "/settle") })?.tabID else {
            throw Failure("The settle fixture tab was not announced.")
        }
        let page = try await devtools.page(urlContaining: "/settle")

        let tools = MacTools(catalog: AppCatalog(), browserService: service)
        tools.showApproval = { [weak tools] in
            guard let tools, let approval = tools.approval else { return }
            tools.resolve(id: approval.id, allow: true)
        }
        func run(_ name: String, _ args: [String: Any]) async throws -> (result: [String: Any], raw: String, ms: Double) {
            var args = args
            args["tab_id"] = tabID
            let data = try JSONSerialization.data(withJSONObject: args)
            let clock = ContinuousClock(), start = clock.now
            let raw = try await tools.execute(name: name, arguments: String(decoding: data, as: UTF8.self))
            let ms = milliseconds(start.duration(to: clock.now))
            return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:], raw, ms)
        }
        func evaluate(_ expression: String) async -> String {
            let r = try? await devtools.call(page, "Runtime.evaluate", ["expression": expression, "returnByValue": true])
            return (r?["result"] as? [String: Any])?["value"].map { "\($0)" } ?? ""
        }
        /// Loads `url` in the tab, waits for the document, and authorizes it as it really is.
        func open(_ url: String) async throws {
            let before = await evaluate("performance.timeOrigin")
            _ = try await devtools.call(page, "Page.navigate", ["url": url])
            _ = try await waitUntil("\(url) to load", timeout: 30) {
                let now = await evaluate("performance.timeOrigin + '|' + document.readyState")
                return !now.hasPrefix(before + "|") && now.hasSuffix("|complete")
            }
            let href = await evaluate("location.href"), title = await evaluate("document.title")
            runtime.setTab(id: tabID, title: title, url: href)
            guard let tab = try await service.listTabs().first(where: { $0.id == tabID }) else { throw Failure("Tab listing lost the tab.") }
            _ = try await service.authorizeListedTab(tab)
        }
        func elementID(_ label: String, action: String? = nil) async throws -> String {
            let read = try await run("read_browser_tab", [:])
            let lines = parsePage(read.result["page"] as? String ?? "")
            guard let match = lines.first(where: { ($0["label"] as? String) == label && (action == nil || ($0["action"] as? String) == action) }),
                  let id = match["id"] as? String else {
                throw Failure("'\(label)' is not in the read; got \(lines.prefix(40).compactMap { $0["label"] as? String }).")
            }
            return id
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        func fmt(_ ms: Double) -> String { String(format: "%.0f ms", ms) }
        func report(_ what: String, _ times: [Double], _ outcome: String) {
            print("  \(what): median \(fmt(median(times))) (min \(fmt(times.min()!)), max \(fmt(times.max()!)), n=\(times.count)) — \(outcome)")
        }

        // 1. A button whose results come from a request that takes 450 ms.
        try await open(base + "/settle")
        var times: [Double] = [], seen = 0, sizes: [Int] = []
        for round in 1...5 {
            let label = round == 1 ? "Load results" : "Loaded \((round - 1) * 5) results"
            let clicked = try await run("click_browser_element", ["element_id": try await elementID(label)])
            guard clicked.result["ok"] as? Bool == true else { throw Failure("Load click failed: \(clicked.raw)") }
            times.append(clicked.ms)
            sizes.append(clicked.raw.utf8.count)
            if clicked.raw.contains("Result item \(round).") { seen += 1 }
            _ = try await waitUntil("results to arrive", timeout: 5) { await evaluate("results.children.length") == "\(round * 5)" }
        }
        report("Button loading results (450 ms request)", times, "result showed the new items in \(seen)/5, result size median \(median(sizes.map(Double.init)).formatted()) bytes")

        // 2. A change that comes from a timer alone, 450 ms after the click.
        let revealed = try await run("click_browser_element", ["element_id": try await elementID("Reveal later")])
        print("  Button revealing text after a 450 ms timer: \(fmt(revealed.ms)) — result \(revealed.raw.contains("Revealed: yes") ? "showed" : "did not show") the change")

        // 3. A click that changes no DOM (it only draws on a canvas).
        times = []
        var lastNoop = ""
        for _ in 1...3 {
            let clicked = try await run("click_browser_element", ["element_id": try await elementID("Draw on canvas")])
            times.append(clicked.ms)
            lastNoop = clicked.raw
        }
        let noopSays = lastNoop.contains("no_dom_change") ? "result says nothing on the page changed" : "result does not say whether anything changed"
        report("Canvas-only button", times, noopSays)

        // 4. Scrolling reports what came into view.
        try await open(base + "/select")
        let scrolled = try await run("scroll_browser_tab", ["direction": "down", "amount": 3])
        guard scrolled.result["ok"] as? Bool == true, scrolled.result["verified"] as? Bool == true else {
            throw Failure("Page scroll failed (\(fmt(scrolled.ms))): \(scrolled.raw)")
        }
        let view = scrolled.result["after"] as? [String: Any] ?? [:]
        print("  Page scroll: \(fmt(scrolled.ms)), verified, result \(view["new_text"] != nil || view["changed"] != nil ? "shows what changed" : "has no change report")")

        // 5. Finding controls by meaning instead of by an id from a read.
        try await open(base + "/settle")
        _ = try await run("click_browser_element", ["element_id": try await elementID("Load results")])
        _ = try await waitUntil("results to arrive", timeout: 5) { await evaluate("results.children.length") == "5" }
        let probe = try await run("find_browser_element", ["text": "Preview draft"])
        if (probe.result["error"] as? String)?.hasPrefix("Unsupported") == true {
            print("  find_browser_element: not available in this build")
        } else {
            for (text, role, expected) in [("Preview draft", "button", "Preview draft"), ("Read the docs", "link", "Read the docs"),
                                           ("Close dialog", "button", "×"), ("Shadow action", nil, "Shadow action"),
                                           ("result item 1.3", nil, "Result item 1.3")] as [(String, String?, String)] {
                var args: [String: Any] = ["text": text]
                if let role { args["role"] = role }
                let found = try await run("find_browser_element", args)
                let lines = parsePage(found.result["matches"] as? String ?? "")
                guard found.result["ok"] as? Bool == true, (lines.first?["label"] as? String) == expected else {
                    throw Failure("find '\(text)' did not resolve \(expected) first: \(found.raw)")
                }
                print("  find '\(text)'\(role.map { " role \($0)" } ?? ""): first match '\(expected)' (\(lines.count) match\(lines.count == 1 ? "" : "es"), \(fmt(found.ms)))")
            }
            let missing = try await run("find_browser_element", ["text": "Nothing like this anywhere"])
            guard missing.result["ok"] as? Bool == true, (missing.result["count"] as? Int) == 0 else {
                throw Failure("A missing text should return zero matches: \(missing.raw)")
            }
            let found = try await run("find_browser_element", ["text": "Preview draft", "role": "button"])
            guard let previewID = parsePage(found.result["matches"] as? String ?? "").first?["id"] as? String else { throw Failure("No id for Preview draft.") }
            let previewed = try await run("click_browser_element", ["element_id": previewID])
            guard previewed.result["verified"] as? Bool == true, await evaluate("document.getElementById('previewed').textContent") == "Previewed: 1" else {
                throw Failure("Clicking the found Preview draft button failed: \(previewed.raw)")
            }
            print("PASS: find_browser_element resolved split text, a link, an aria-label, a shadow-root button and a result row; a found id was clicked without a read and the page saw one trusted click.")
        }

        // 6. A real site: hide Wikipedia's contents list (a pure DOM change on a
        // large page), then follow an article link (a new document).
        try await open("https://en.wikipedia.org/wiki/Stockholm")
        let hidden = try await run("click_browser_element", ["element_id": try await elementID("hide")])
        let after = hidden.result["after"] as? [String: Any] ?? [:]
        let lines = { (key: String) in parsePage(after[key] as? String ?? "").count }
        let shape = after["page"] != nil ? "a full re-read (\(lines("page")) element lines)"
            : after["no_dom_change"] != nil ? "no change reported"
            : "changes only: \(lines("added")) added, \(lines("changed")) changed, \(after["removed_elements"] as? Int ?? 0) removed elements, \((after["new_text"] as? String)?.split(separator: "\n").count ?? 0) new text lines"
        print("  Wikipedia: click 'hide' on the contents: \(fmt(hidden.ms)), verified \(hidden.result["verified"] as? Bool == true), result is \(shape), \(hidden.raw.utf8.count) bytes")
        try await open("https://en.wikipedia.org/wiki/Stockholm")
        let linkID = try await elementID("Sweden", action: "follow")
        let followed = try await run("click_browser_element", ["element_id": linkID])
        let landed = followed.raw.contains("wiki\\/Sweden") && followed.result["verified"] as? Bool == true
        print("  Wikipedia: follow the 'Sweden' link: \(fmt(followed.ms)), \(landed ? "verified, result shows the Sweden article" : "not verified or wrong page"), \(followed.raw.utf8.count) bytes")
        print("PASS: Browser settle check finished.")
    }
}
