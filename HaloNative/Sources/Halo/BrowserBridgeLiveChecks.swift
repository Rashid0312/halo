import AppKit
import Darwin
import HaloBridge

/// Real-browser lifecycle, performance, and cleanup checks for the Phase 5A
/// bridge. Everything runs through production code — `BrowserBridgeController`,
/// the browser-launched `HaloNativeHost`, the pinned extension, and
/// `ChromeBrowserService.readTab` — against an isolated Chromium profile. Only
/// the AppleScript tab listing is replaced, fed from the extension's own
/// announcements. The browser is driven externally over the DevTools protocol,
/// so the extension carries no test-only entry points.
extension NativeChecks {
    final class AnnouncedTabsRuntime: BrowserAutomationRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var tabs: [(id: Int, title: String, url: String)] = []

        func setBrowser(pid: pid_t) { lock.withLock { self.pid = pid; self.tabs = [] } }
        func setTab(id: Int, title: String, url: String) {
            lock.withLock {
                tabs.removeAll { $0.id == id }
                tabs.append((id, title, url))
            }
        }
        func removeTab(id: Int) { lock.withLock { tabs.removeAll { $0.id == id } } }

        func resolveBrowserContext(_ requestedBundleID: String?) throws -> ChromeBrowserService.BrowserContext {
            let pid = lock.withLock { self.pid }
            guard pid > 0 else { throw InteractionError("Chromium is not running.") }
            return .init(bundleID: "org.chromium.Chromium", name: "Chromium", pid: pid, sessionID: "\(pid):live-check")
        }

        func runAppleScript(_ script: String) async throws -> String {
            let tabs = lock.withLock { self.tabs }
            return tabs.enumerated().map { index, tab in
                ["\(tab.id)", "1", "\(index + 1)", "1", tab.title, tab.url].joined(separator: "\u{1F}")
            }.joined(separator: "\u{1E}")
        }
    }

    /// Minimal Chrome DevTools Protocol client for the disposable test browser.
    struct DevToolsClient {
        let port: Int

        static func attach(profile: URL, timeout: TimeInterval = 15) async throws -> DevToolsClient {
            let file = profile.appendingPathComponent("DevToolsActivePort")
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let text = try? String(contentsOf: file, encoding: .utf8),
                   let port = Int(text.split(separator: "\n").first ?? "") {
                    return DevToolsClient(port: port)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure("Chromium did not publish a DevTools port.")
        }

        private func http(_ path: String, method: String = "GET") async throws -> Data {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            return try await URLSession.shared.data(for: request).0
        }

        func pages() async throws -> [[String: Any]] {
            let list = try JSONSerialization.jsonObject(with: try await http("/json/list")) as? [[String: Any]] ?? []
            return list.filter { $0["type"] as? String == "page" }
        }

        func page(urlContaining fragment: String) async throws -> [String: Any] {
            guard let page = try await pages().first(where: { ($0["url"] as? String)?.contains(fragment) == true }) else {
                throw Failure("No DevTools page target matches \(fragment).")
            }
            return page
        }

        func openTab(_ url: String) async throws {
            _ = try await http("/json/new?\(url)", method: "PUT")
        }

        func close(page: [String: Any]) async throws {
            guard let id = page["id"] as? String else { throw Failure("DevTools page has no id.") }
            _ = try await http("/json/close/\(id)")
        }

        @discardableResult
        func call(_ page: [String: Any], _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            guard let ws = page["webSocketDebuggerUrl"] as? String else { throw Failure("DevTools target has no WebSocket.") }
            return try await call(webSocket: ws, method, params)
        }

        func browserCall(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let version = try JSONSerialization.jsonObject(with: try await http("/json/version")) as? [String: Any]
            guard let ws = version?["webSocketDebuggerUrl"] as? String else { throw Failure("DevTools browser endpoint missing.") }
            return try await call(webSocket: ws, method, params)
        }

        private func call(webSocket: String, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let task = URLSession.shared.webSocketTask(with: URL(string: webSocket)!)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }
            let payload = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
            try await task.send(.string(String(decoding: payload, as: UTF8.self)))
            while true {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: continue
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["id"] as? Int == 1 else { continue }
                if let error = object["error"] { throw Failure("DevTools \(method) failed: \(error)") }
                return object["result"] as? [String: Any] ?? [:]
            }
        }
    }

    private static func waitUntil(_ what: String, timeout: TimeInterval = 15,
                                  _ condition: @MainActor () async -> Bool) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return start.duration(to: clock.now) }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure("Timed out after \(Int(timeout))s waiting for \(what).")
    }

    private static func pids(matching pattern: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    /// A crashed earlier run cannot run its cleanup. Stop browsers still using one
    /// of this suite's disposable profiles so they are never mistaken for the
    /// user's browser, then remove those profiles.
    static func reapOrphanedTestBrowsers() async {
        let temp = FileManager.default.temporaryDirectory.path
        for prefix in ["halo-bridge-live-", "halo-browser-probe-"] {
            let orphans = pids(matching: "user-data-dir=\(temp)/?\(prefix)")
            for pid in orphans { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(3)
            while orphans.contains(where: { kill($0, 0) == 0 }), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for pid in orphans where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: temp) {
                for entry in entries where entry.hasPrefix(prefix) {
                    try? FileManager.default.removeItem(atPath: (temp as NSString).appendingPathComponent(entry))
                }
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor
    static func runRealBrowserLifecycleSuite(helperBinaryURL: URL) async throws {
        print("--- Phase 5A: Real Chromium Lifecycle Suite ---")
        await reapOrphanedTestBrowsers()
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
                .appendingPathComponent(".local-tools/chromium/chrome-mac/Chromium.app/Contents/MacOS/Chromium"),
            URL(fileURLWithPath: "/Applications/Chromium.app/Contents/MacOS/Chromium")
        ]
        guard let browserURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw Failure("Phase 5A lifecycle suite requires an unbranded Chromium build (.local-tools/chromium).")
        }
        let extPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/BrowserBridgeExtension").standardized.path
        let extensionID = BrowserBridgeController.developmentExtensionID

        let fixture = try DisposableTabServer()
        defer { fixture.stop() }
        let base = "http://127.0.0.1:\(fixture.port)"
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("halo-bridge-live-\(UUID().uuidString)", isDirectory: true)
        let manifestDir = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let manifestFile = manifestDir.appendingPathComponent("\(BrowserBridgeController.hostName).json")
        let defaultsSuite = "app.halo.bridge-live-check.\(getpid())"
        let defaults = UserDefaults(suiteName: defaultsSuite)!

        let runtime = AnnouncedTabsRuntime()
        let service = ChromeBrowserService(runtime: runtime)
        let controller = BrowserBridgeController(service: service, helperURL: helperBinaryURL,
                                                 manifestDirectories: { [manifestDir] in [manifestDir] }, defaults: defaults)
        var browser: Process?
        func launchBrowser(_ url: String) throws -> Process {
            let process = Process()
            process.executableURL = browserURL
            process.arguments = [
                "--user-data-dir=\(profile.path)", "--remote-debugging-port=0",
                "--no-first-run", "--no-default-browser-check",
                "--disable-extensions-except=\(extPath)", "--load-extension=\(extPath)", url
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            runtime.setBrowser(pid: process.processIdentifier)
            return process
        }
        defer {
            controller.shutdownForTermination()
            if let browser { terminateProcessBounded(browser) }
            try? FileManager.default.removeItem(at: profile)
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        }

        func isConnected() -> Bool { if case .connected = controller.status { return true } else { return false } }
        func announced(_ path: String) throws -> BridgeTabAnnouncement {
            guard let tab = controller.announcements.first(where: { $0.url.hasPrefix(base + path) }) else {
                throw Failure("Extension did not announce \(path); got \(controller.announcements.map(\.url)).")
            }
            return tab
        }
        func authorize(_ id: Int, url: String, title: String = "Halo Disposable Browser Fixture") async throws {
            runtime.setTab(id: id, title: title, url: url)
            guard let tab = try await service.listTabs().first(where: { $0.id == id }) else {
                throw Failure("Stub listing lost tab \(id).")
            }
            _ = try await service.authorizeObservedTab(tab)
        }
        func expectRejected(_ what: String, _ body: () async throws -> Void) async throws -> String {
            do { try await body() } catch { return error.localizedDescription }
            throw Failure("\(what) was not rejected.")
        }
        /// Sends an observe request for a deliberately stale generation directly over
        /// the authenticated bridge and returns the extension's error code.
        func staleGenerationCode(tabID: Int, generation: UInt64, url: String) async throws -> String {
            guard let server = await service.activeBridgeServer() else { throw Failure("Bridge is not attached.") }
            let pid = runtime.pidForChecks
            let target = TabGenerationIdentity(browser: BrowserIdentity(bundleID: "org.chromium.Chromium", sessionID: "\(pid):live-check", pid: pid),
                                               tabID: tabID, documentGenerationID: generation, url: url, domain: "127.0.0.1")
            let request = BridgeRequest(requestID: BridgeSocketIO.generateRandomHex(byteCount: 8),
                                        sessionNonce: server.sessionConfig.sessionNonce, type: .observeTab, targetTab: target)
            try await server.sendRequest(request)
            while true {
                let response = try await server.receiveResponse(timeoutSeconds: 5)
                guard response.requestID == request.requestID else { continue }
                guard !response.success, let error = response.error else { throw Failure("Stale generation \(generation) was observed.") }
                return "\(error.code)"
            }
        }

        var results: [String] = []
        func pass(_ line: String) { print("PASS: \(line)"); results.append(line) }

        // 1. Opt-in lifecycle: enabling registers the manifest and waits.
        controller.enabled = true
        guard controller.status == .waiting, FileManager.default.fileExists(atPath: manifestFile.path) else {
            throw Failure("Enabling the bridge did not register the manifest: \(controller.status.summary)")
        }
        guard defaults.bool(forKey: "browserBridgeEnabled") else {
            throw Failure("Opt-in was not persisted.")
        }
        browser = try launchBrowser(base + "/halo-test")
        let coldConnect = try await waitUntil("cold extension handshake", timeout: 20) { isConnected() }
        let devtools = try await DevToolsClient.attach(profile: profile)
        let tabA = try announced("/halo-test").tabID
        try await authorize(tabA, url: base + "/halo-test")
        let first = try await service.readTab(id: tabA)
        guard first.content.contains("Halo Chrome Integration Test") else { throw Failure("Production read returned wrong content.") }
        pass("Opt-in bridge: manifest registered, browser-launched helper authenticated, pinned handshake completed, production readTab returned real DOM (cold connect \(String(format: "%.0f", milliseconds(coldConnect))) ms).")

        var observeSamples: [Double] = []
        for _ in 0..<30 {
            let clock = ContinuousClock(), start = clock.now
            _ = try await service.readTab(id: tabA)
            observeSamples.append(milliseconds(start.duration(to: clock.now)))
        }

        // 2. Same-site navigation advances the generation; the old one is rejected.
        try await devtools.call(try await devtools.page(urlContaining: "/halo-test"), "Page.navigate", ["url": base + "/large"])
        try await Task.sleep(for: .milliseconds(800))
        let afterNav = try await service.readTab(id: tabA)
        guard afterNav.url.hasSuffix("/large"), afterNav.content.contains("Fixture control") else {
            throw Failure("Read after same-site navigation did not follow the new document.")
        }
        let navCode = try await staleGenerationCode(tabID: tabA, generation: 1, url: base + "/large")
        guard navCode.localizedCaseInsensitiveContains("stale") else { throw Failure("Pre-navigation generation returned \(navCode).") }
        pass("Navigation: authorization followed same-site navigation to the new document; pre-navigation generation rejected (\(navCode)).")

        // 3. Reload is a new document generation too.
        try await devtools.call(try await devtools.page(urlContaining: "/large"), "Page.reload")
        try await Task.sleep(for: .milliseconds(800))
        _ = try await service.readTab(id: tabA)
        let reloadCode = try await staleGenerationCode(tabID: tabA, generation: 2, url: base + "/large")
        guard reloadCode.localizedCaseInsensitiveContains("stale") else { throw Failure("Pre-reload generation returned \(reloadCode).") }
        pass("Reload: new document generation required; pre-reload generation rejected (\(reloadCode)).")

        // 4–6. Pause, revoke, and cancellation while a read is in flight never
        // deliver content and never desynchronize the bridge stream. Offsets are
        // staggered until each interruption lands after the request was sent.
        let offsetsMicros: [UInt64] = [0, 100, 250, 500, 750, 1000, 1500, 2000, 3000]
        func interrupt(_ label: String, _ action: () async -> Void, restore: () async throws -> Void) async throws -> (inFlight: Int, attempts: Int) {
            var inFlight = 0, attempts = 0
            while inFlight == 0 && attempts < 40 {
                let offset = offsetsMicros[attempts % offsetsMicros.count]
                attempts += 1
                let read = Task { try await service.readTab(id: tabA) }
                if offset > 0 { try await Task.sleep(nanoseconds: offset * 1000) }
                await action()
                if case .failure(let error) = await read.result {
                    let message = error.localizedDescription
                    if message.contains("in flight") || message.contains("failed closed") { inFlight += 1 }
                }
                try await restore()
                let next = try await service.readTab(id: tabA)
                guard next.url.hasSuffix("/large"), next.content.contains("Fixture control") else {
                    throw Failure("\(label): read after interruption returned the wrong document.")
                }
            }
            guard inFlight > 0 else { throw Failure("\(label) never landed while a read was in flight (\(attempts) attempts).") }
            return (inFlight, attempts)
        }

        let paused = try await interrupt("Pause", { await service.setPaused(true) }, restore: { await service.setPaused(false) })
        pass("Pause during observation: in-flight read suppressed (caught after \(paused.attempts) attempt(s)); every following read correlated correctly.")

        let revoked = try await interrupt("Revoke", { await service.revoke(tabID: tabA) }, restore: {
            _ = try await expectRejected("Read after revoke") { _ = try await service.readTab(id: tabA) }
            try await authorize(tabA, url: base + "/large")
        })
        pass("Revoke during observation: in-flight read suppressed (caught after \(revoked.attempts) attempt(s)); tab unreadable until re-approved, re-approval tracked the live generation.")

        var cancelTask: Task<BrowserTabContent, Error>?
        var cancelHits = 0, cancelAttempts = 0
        while cancelHits == 0 && cancelAttempts < 40 {
            let offset = offsetsMicros[cancelAttempts % offsetsMicros.count]
            cancelAttempts += 1
            cancelTask = Task { try await service.readTab(id: tabA) }
            if offset > 0 { try await Task.sleep(nanoseconds: offset * 1000) }
            cancelTask?.cancel()
            if case .failure(let error) = await cancelTask!.result, error.localizedDescription.contains("failed closed") { cancelHits += 1 }
            let next = try await service.readTab(id: tabA)
            guard next.url.hasSuffix("/large") else { throw Failure("Read after cancellation returned the wrong document.") }
        }
        guard cancelHits > 0 else { throw Failure("Cancellation never landed while a response was pending (\(cancelAttempts) attempts).") }
        pass("Cancellation during observation: abandoned in-flight response discarded (caught after \(cancelAttempts) attempt(s)); next read correlated correctly.")

        // 7. Cross-domain navigation revokes.
        try await devtools.call(try await devtools.page(urlContaining: "/large"), "Page.navigate",
                                ["url": "http://localhost:\(fixture.port)/halo-test"])
        try await Task.sleep(for: .milliseconds(800))
        let crossMessage = try await expectRejected("Read after cross-domain navigation") { _ = try await service.readTab(id: tabA) }
        guard await !service.isAuthorized(tabID: tabA) else { throw Failure("Cross-domain navigation kept the authorization.") }
        pass("Cross-domain navigation revoked authorization (\(crossMessage)).")

        // 8. Tab closure.
        try await devtools.call(try await devtools.page(urlContaining: "localhost"), "Page.navigate", ["url": base + "/halo-test"])
        try await Task.sleep(for: .milliseconds(800))
        try await authorize(tabA, url: base + "/halo-test")
        _ = try await service.readTab(id: tabA)
        try await devtools.openTab(base + "/page-b")
        try await Task.sleep(for: .milliseconds(800))
        try await devtools.close(page: try await devtools.page(urlContaining: "/halo-test"))
        try await Task.sleep(for: .milliseconds(500))
        runtime.removeTab(id: tabA)
        _ = try await expectRejected("Read of closed tab") { _ = try await service.readTab(id: tabA) }
        guard await !service.isAuthorized(tabID: tabA) else { throw Failure("Closed tab kept its authorization.") }
        pass("Tab closure removed authorization and rejected further reads.")

        // 9. Helper crash and warm reconnection.
        guard let helperPID = await service.activeBridgeServer()?.peerPID, helperPID > 0 else {
            throw Failure("Could not identify the browser-launched helper.")
        }
        let crashClock = ContinuousClock(), crashStart = crashClock.now
        kill(helperPID, SIGKILL)
        _ = try await waitUntil("helper loss detection", timeout: 5) { !isConnected() }
        let detectCrash = crashStart.duration(to: crashClock.now)
        _ = try await waitUntil("warm reconnection", timeout: 15) { isConnected() }
        let warmReconnect = crashStart.duration(to: crashClock.now)
        guard await service.authorizedCount() == 0 else { throw Failure("Authorizations survived a helper crash.") }
        let tabB = try announced("/page-b").tabID
        try await authorize(tabB, url: base + "/page-b", title: "Halo Fixture Page B")
        guard try await service.readTab(id: tabB).content.contains("Halo Fixture Page B") else { throw Failure("Read after reconnect failed.") }
        pass("Helper crash (SIGKILL): loss detected in \(String(format: "%.0f", milliseconds(detectCrash))) ms, extension relaunched helper, re-handshake in \(String(format: "%.0f", milliseconds(warmReconnect))) ms, prior authorizations revoked.")

        // 10. Extension service-worker restart.
        let targets = try await devtools.browserCall("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        guard let worker = targets.first(where: { $0["type"] as? String == "service_worker" &&
                                                 ($0["url"] as? String)?.hasPrefix("chrome-extension://\(extensionID)/") == true }),
              let workerID = worker["targetId"] as? String else {
            throw Failure("Extension service worker target not found.")
        }
        _ = try await devtools.browserCall("Target.closeTarget", ["targetId": workerID])
        _ = try await waitUntil("disconnect after worker stop", timeout: 10) { !isConnected() }
        try await devtools.call(try await devtools.page(urlContaining: "/page-b"), "Page.reload")
        _ = try await waitUntil("reconnect after worker restart", timeout: 20) { isConnected() }
        guard await service.authorizedCount() == 0 else { throw Failure("Authorizations survived a worker restart.") }
        let tabB2 = try announced("/page-b").tabID
        try await authorize(tabB2, url: base + "/page-b", title: "Halo Fixture Page B")
        _ = try await service.readTab(id: tabB2)
        pass("Extension service-worker restart: helper disconnected, worker woke on page load, fresh handshake required, prior authorizations revoked.")

        // 11. Idle resources with the extension connected. Longer than the
        // helper's former 60s read timeout, so an idle bridge must stay up.
        guard let idleServer = await service.activeBridgeServer(), case let idleHelper = await idleServer.peerPID, idleHelper > 0 else {
            throw Failure("Connected helper not found for idle sampling.")
        }
        let haloBefore = getProcessTelemetry(pid: getpid()), helperBefore = getProcessTelemetry(pid: idleHelper)
        let idleSeconds = 65.0
        for second in 1...Int(idleSeconds) {
            try await Task.sleep(for: .seconds(1))
            guard isConnected(), kill(idleHelper, 0) == 0 else {
                throw Failure("Idle bridge dropped after \(second)s: status=\(controller.status.summary) helperAlive=\(kill(idleHelper, 0) == 0).")
            }
        }
        let haloAfter = getProcessTelemetry(pid: getpid()), helperAfter = getProcessTelemetry(pid: idleHelper)
        guard await idleServer.peerPID == idleHelper else {
            throw Failure("The helper was replaced during \(Int(idleSeconds))s idle.")
        }
        let helperCPU = Double((helperAfter.userTimeNano + helperAfter.systemTimeNano) &- (helperBefore.userTimeNano + helperBefore.systemTimeNano)) / 1e9 / idleSeconds * 100
        let haloCPU = Double((haloAfter.userTimeNano + haloAfter.systemTimeNano) &- (haloBefore.userTimeNano + haloBefore.systemTimeNano)) / 1e9 / idleSeconds * 100
        pass("Connected idle for \(Int(idleSeconds))s: same helper process, bridge still attached.")

        // 12. Browser restart.
        if let running = browser { terminateProcessBounded(running) }
        _ = try await waitUntil("disconnect after browser exit", timeout: 10) { !isConnected() }
        browser = try launchBrowser(base + "/halo-test")
        _ = try await waitUntil("reconnect after browser restart", timeout: 20) { isConnected() }
        guard await service.authorizedCount() == 0 else { throw Failure("Authorizations survived a browser restart.") }
        let tabC = try announced("/halo-test").tabID
        try await authorize(tabC, url: base + "/halo-test")
        _ = try await service.readTab(id: tabC)
        pass("Browser restart: new browser session re-handshaked; previous session's authorizations invalid; new tab readable after approval.")

        // 13. Disable: no manifest, session, socket, or helper may remain.
        let finalSession = await service.activeBridgeServer()?.directoryURL
        controller.enabled = false
        guard controller.status == .off, !FileManager.default.fileExists(atPath: manifestFile.path) else {
            throw Failure("Disabling did not remove the manifest.")
        }
        _ = try await waitUntil("session teardown", timeout: 5) {
            finalSession.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        }
        if let finalSession {
            _ = try await waitUntil("helper exit", timeout: 5) {
                pids(matching: "HaloNativeHost --session-dir \(finalSession.path)").isEmpty
            }
        }
        guard await service.activeBridgeServer() == nil else { throw Failure("Bridge stayed attached after disable.") }
        let lastBrowserPID = browser?.processIdentifier
        if let running = browser { terminateProcessBounded(running) }
        browser = nil
        guard pids(matching: profile.path).isEmpty else { throw Failure("Chromium processes outlived the suite.") }
        // Later checks resolve the user's browser through NSWorkspace; let it
        // observe the test browser's exit so it is not mistaken for theirs.
        if let lastBrowserPID {
            _ = try await waitUntil("NSWorkspace to observe test browser exit", timeout: 10) {
                NSRunningApplication(processIdentifier: lastBrowserPID).map { $0.isTerminated } ?? true
            }
        }
        pass("Disable: manifest removed, session directory and socket removed, helper exited, bridge detached; no browser processes remain.")

        let navigateTimes = observeSamples
        print("""
        | Real-browser metric | Samples | p50 | p95 | Max | Threshold | Result |
        |---|---|---|---|---|---|---|
        | DOM observation via production readTab (round trip) | 30 | \(String(format: "%.2f ms", percentile(navigateTimes, 0.5))) | \(String(format: "%.2f ms", percentile(navigateTimes, 0.95))) | \(String(format: "%.2f ms", navigateTimes.max() ?? 0)) | p50 <= 300 ms, p95 <= 1000 ms | \(percentile(navigateTimes, 0.5) <= 300 && percentile(navigateTimes, 0.95) <= 1000 ? "PASS" : "FAIL") |
        | Cold connect (browser launch to Halo status connected) | 1 | \(String(format: "%.0f ms", milliseconds(coldConnect))) | - | - | Recorded | PASS |
        | Helper loss detection | 1 | \(String(format: "%.0f ms", milliseconds(detectCrash))) | - | - | <= 1000 ms | \(milliseconds(detectCrash) <= 1000 ? "PASS" : "FAIL") |
        | Warm reconnection (helper killed to re-handshaked) | 1 | \(String(format: "%.0f ms", milliseconds(warmReconnect))) | - | - | <= 5000 ms | \(milliseconds(warmReconnect) <= 5000 ? "PASS" : "FAIL") |
        | Connected-idle helper CPU / RSS | 65s | \(String(format: "%.2f%%", helperCPU)) | \(String(format: "%.1f MiB", Double(helperAfter.rssBytes) / 1_048_576)) | - | CPU < 1% | \(helperCPU < 1 ? "PASS" : "FAIL") |
        | Connected-idle Halo CPU / RSS delta | 65s | \(String(format: "%.2f%%", haloCPU)) | \(String(format: "%+.1f KiB", (Double(haloAfter.rssBytes) - Double(haloBefore.rssBytes)) / 1024)) | - | CPU < 2% | \(haloCPU < 2 ? "PASS" : "FAIL") |
        """)
        guard percentile(navigateTimes, 0.5) <= 300, percentile(navigateTimes, 0.95) <= 1000,
              milliseconds(detectCrash) <= 1000, milliseconds(warmReconnect) <= 5000, helperCPU < 1, haloCPU < 2 else {
            throw Failure("Real-browser performance thresholds not met.")
        }
        print("PASS: Phase 5A real Chromium lifecycle suite: \(results.count) stages verified end to end.")
    }
}

extension NativeChecks.AnnouncedTabsRuntime {
    var pidForChecks: pid_t { (try? resolveBrowserContext(nil).pid) ?? 0 }
}
