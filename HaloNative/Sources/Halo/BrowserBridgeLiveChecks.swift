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
        private var readResponses: [Int: String] = [:]

        /// Answers the AppleScript read path for a tab the bridge does not cover.
        func setReadResponse(id: Int, title: String, url: String, text: String) {
            let json = (try? JSONSerialization.data(withJSONObject: ["title": title, "url": url, "text": text])) ?? Data()
            lock.withLock { readResponses[id] = String(decoding: json, as: UTF8.self) }
        }

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
            if script.contains("execute t javascript") {
                let responses = lock.withLock { readResponses }
                guard let match = script.range(of: #"is "(\d+)""#, options: .regularExpression),
                      let id = Int(script[match].filter(\.isNumber)), let response = responses[id] else { return "NOT_FOUND" }
                return response
            }
            let tabs = lock.withLock { self.tabs }
            return tabs.enumerated().map { index, tab in
                ["\(tab.id)", "1", "\(index + 1)", "1", tab.title, tab.url].joined(separator: "\u{1F}")
            }.joined(separator: "\u{1E}")
        }
    }

    /// Minimal Chrome DevTools Protocol client for the disposable test browser.
    @MainActor struct DevToolsClient {
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
        BridgeSessionConfig.removeAbandonedSessionDirectories()
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
        let extensionID = BrowserBridgeController.developmentExtensionID

        let fixture = try DisposableTabServer()
        defer { fixture.stop() }
        let base = "http://127.0.0.1:\(fixture.port)"
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("halo-bridge-live-\(UUID().uuidString)", isDirectory: true)
        let manifestDir = profile.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // The suite loads a copy of the extension with Site access narrowed to
        // loopback, as a user can do in Chrome; *.localhost hosts then stand in
        // for sites the user has not granted. The shipped manifest grants all
        // http(s) sites (checked separately).
        let restrictedExtension = profile.appendingPathComponent("extension-restricted", isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/BrowserBridgeExtension"), to: restrictedExtension)
        let restrictedManifestURL = restrictedExtension.appendingPathComponent("manifest.json")
        var restrictedManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: restrictedManifestURL)) as? [String: Any] ?? [:]
        restrictedManifest["host_permissions"] = ["http://127.0.0.1/*", "http://localhost/*"]
        try JSONSerialization.data(withJSONObject: restrictedManifest, options: [.prettyPrinted]).write(to: restrictedManifestURL)
        let extPath = restrictedExtension.path
        let uncoveredBase = "http://halo-uncovered.localhost:\(fixture.port)"
        let manifestFile = manifestDir.appendingPathComponent("\(BrowserBridgeController.hostName).json")
        let defaultsSuite = "app.halo.bridge-live-check.\(getpid())"
        let defaults = UserDefaults(suiteName: defaultsSuite)!

        let runtime = AnnouncedTabsRuntime()
        let service = ChromeBrowserService(runtime: runtime)
        let controller = BrowserBridgeController(service: service, helperURL: helperBinaryURL,
                                                 manifestDirectories: { [manifestDir] in [manifestDir] }, defaults: defaults)
        var browser: Process?
        func launchBrowser(_ urls: String...) throws -> Process {
            // A stale port file from the previous browser must not be reused.
            try? FileManager.default.removeItem(at: profile.appendingPathComponent("DevToolsActivePort"))
            let process = Process()
            process.executableURL = browserURL
            process.arguments = [
                "--user-data-dir=\(profile.path)", "--remote-debugging-port=0",
                "--no-first-run", "--no-default-browser-check",
                "--disable-extensions-except=\(extPath)", "--load-extension=\(extPath)"
            ] + urls
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
        /// Bounded wait for a page target to finish loading a document newer than
        /// `previous` (its performance.timeOrigin), instead of a fixed delay.
        func documentOrigin(_ page: [String: Any]) async -> (origin: Double, complete: Bool)? {
            guard let result = try? await devtools.call(page, "Runtime.evaluate",
                      ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? String else { return nil }
            let parts = value.split(separator: "|")
            guard parts.count == 2, let origin = Double(parts[0]) else { return nil }
            return (origin, parts[1] == "complete")
        }
        func navigate(_ page: [String: Any], _ method: String, _ params: [String: Any] = [:]) async throws {
            let before = await documentOrigin(page)?.origin ?? 0
            try await devtools.call(page, method, params)
            _ = try await waitUntil("\(method) to load a new document", timeout: 10) {
                guard let now = await documentOrigin(page) else { return false }
                return now.origin != before && now.complete
            }
        }
        /// Polls Halo's production read until it satisfies `condition`.
        func readUntil(_ what: String, id: Int? = nil, _ condition: @escaping (BrowserTabContent) -> Bool) async throws -> BrowserTabContent {
            var latest: BrowserTabContent?
            var lastIssue = "no read attempted"
            do {
                _ = try await waitUntil(what, timeout: 10) {
                    do {
                        let content = try await service.readTab(id: id ?? tabA)
                        guard condition(content) else { lastIssue = "read '\(content.title)' at \(content.url)"; return false }
                        latest = content
                        return true
                    } catch {
                        lastIssue = error.localizedDescription
                        return false
                    }
                }
            } catch {
                throw Failure("\(error.localizedDescription) Last result: \(lastIssue)")
            }
            return latest!
        }
        /// Polls until Halo rejects reads of the tab and no longer lists it authorized.
        func rejectedEventually(_ what: String, id: Int) async throws -> String {
            var message = ""
            _ = try await waitUntil(what, timeout: 10) {
                do { _ = try await service.readTab(id: id); return false }
                catch { message = error.localizedDescription }
                return await !service.isAuthorized(tabID: id)
            }
            return message
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
        let pageA = try await devtools.page(urlContaining: "/halo-test")
        try await navigate(pageA, "Page.navigate", ["url": base + "/large"])
        _ = try await readUntil("read of the navigated document") { $0.url.hasSuffix("/large") && $0.content.contains("Fixture control") }
        let navCode = try await staleGenerationCode(tabID: tabA, generation: 1, url: base + "/large")
        guard navCode.localizedCaseInsensitiveContains("stale") else { throw Failure("Pre-navigation generation returned \(navCode).") }
        pass("Navigation: authorization followed same-site navigation to the new document; pre-navigation generation rejected (\(navCode)).")

        // 3. Reload is a new document generation too.
        try await navigate(pageA, "Page.reload")
        _ = try await readUntil("read of the reloaded document") { $0.url.hasSuffix("/large") }
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
        try await navigate(pageA, "Page.navigate", ["url": "http://localhost:\(fixture.port)/halo-test"])
        let crossMessage = try await rejectedEventually("cross-domain navigation to revoke authorization", id: tabA)
        pass("Cross-domain navigation revoked authorization (\(crossMessage)).")

        // 8. Tab closure.
        try await navigate(pageA, "Page.navigate", ["url": base + "/halo-test"])
        try await authorize(tabA, url: base + "/halo-test")
        _ = try await readUntil("read after returning to the loopback page") { $0.url.hasSuffix("/halo-test") }
        try await devtools.openTab(base + "/page-b")
        _ = try await waitUntil("second tab to load", timeout: 10) {
            guard let page = try? await devtools.page(urlContaining: "/page-b") else { return false }
            return await documentOrigin(page)?.complete == true
        }
        try await devtools.close(page: pageA)
        runtime.removeTab(id: tabA)
        _ = try await rejectedEventually("tab closure to revoke authorization", id: tabA)
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
        browser = try launchBrowser(base + "/halo-test", uncoveredBase + "/halo-test")
        _ = try await waitUntil("reconnect after browser restart", timeout: 20) { isConnected() }
        guard await service.authorizedCount() == 0 else { throw Failure("Authorizations survived a browser restart.") }
        let tabC = try announced("/halo-test").tabID
        try await authorize(tabC, url: base + "/halo-test")
        _ = try await service.readTab(id: tabC)
        pass("Browser restart: new browser session re-handshaked; previous session's authorizations invalid; new tab readable after approval.")

        // 5B.1. Approved click through the production tool, approval, and bridge.
        let devtoolsC = try await DevToolsClient.attach(profile: profile)
        let pageC = try await devtoolsC.page(urlContaining: base + "/halo-test")
        let before = await {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "performance.timeOrigin", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? Double else { return 0.0 }
            return value
        }()
        try await devtoolsC.call(pageC, "Page.navigate", ["url": base + "/click"])
        _ = try await waitUntil("click fixture to load", timeout: 10) {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate",
                      ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? String else { return false }
            let parts = value.split(separator: "|")
            return parts.count == 2 && Double(parts[0]) != before && parts[1] == "complete"
        }
        _ = try await readUntil("click fixture read", id: tabC) { $0.title == "Halo Click Fixture" }

        let tools = MacTools(catalog: AppCatalog(), browserService: service)
        var approvals: [MacTools.Approval] = []
        var decide: (MacTools.Approval) -> Void = { _ in }
        tools.showApproval = { [weak tools] in
            guard let tools, let approval = tools.approval else { return }
            approvals.append(approval)
            decide(approval)
        }
        func run(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: args)
            let raw = try await tools.execute(name: name, arguments: String(decoding: data, as: UTF8.self))
            return try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        }
        func elements() async throws -> [String: [String: Any]] {
            let read = try await run("read_browser_tab", ["tab_id": tabC])
            guard read["ok"] as? Bool == true, let page = read["page"] as? String, case let list = parsePage(page), !list.isEmpty else {
                throw Failure("read_browser_tab returned no element references: \(read)")
            }
            var byLabel: [String: [String: Any]] = [:]
            for element in list {
                guard let label = element["label"] as? String else { continue }
                var key = label, copy = 2
                while byLabel[key] != nil { key = "\(label) #\(copy)"; copy += 1 }
                byLabel[key] = element
            }
            return byLabel
        }
        func elementID(_ map: [String: [String: Any]], _ label: String) throws -> String {
            guard let id = map[label]?["id"] as? String else { throw Failure("Element '\(label)' missing; got \(map.keys.sorted()).") }
            return id
        }
        func click(_ id: String) async throws -> [String: Any] {
            try await run("click_browser_element", ["tab_id": tabC, "element_id": id])
        }

        var map = try await elements()
        for (label, clickable) in [("Clicked 0 times", true), ("Rename me", true), ("Covered button", true), ("Formless action", true),
                                   ("Submit form", true), ("Go to page B", true), ("Disabled action", false), ("(protected)", false)] {
            guard map[label]?["clickable"] as? Bool == clickable else {
                throw Failure("Element '\(label)' clickable flag should be \(clickable); got \(String(describing: map[label])).")
            }
        }
        pass("5B.1 observation: element references returned; plain buttons, the ordinary form's submit, and the same-tab link are clickable; disabled and password are not.")

        // Approve: a genuine (trusted) click lands and is verified.
        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let approved = try await click(try elementID(map, "Clicked 0 times"))
        guard approved["ok"] as? Bool == true, approved["verified"] as? Bool == true,
              let preview = approvals.first, approvals.count == 1,
              preview.path.contains("127.0.0.1"), preview.path.contains("Halo Click Fixture"), preview.preview.contains("Clicked 0 times") else {
            throw Failure("Approved click failed or preview was wrong: \(approved) preview=\(String(describing: approvals.first))")
        }
        map = try await elements()
        guard map["Clicked 1 times"] != nil else { throw Failure("Counter did not show one trusted click; got \(map.keys.sorted()).") }
        pass("5B.1 approved click: preview showed exact site, page, and button; genuine click landed once and was verified (page saw isTrusted).")

        // Deny: nothing happens.
        decide = { tools.resolve(id: $0.id, allow: false) }
        let denied = try await click(try elementID(map, "Clicked 1 times"))
        map = try await elements()
        guard denied["denied"] as? Bool == true, map["Clicked 1 times"] != nil else {
            throw Failure("Denied click changed the page: \(denied)")
        }
        pass("5B.1 denied click: nothing was clicked.")

        // Refused before approval: links, submit, disabled, protected.
        approvals = []
        for label in ["Disabled action", "(protected)"] {
            let refused = try await click(try elementID(map, label))
            guard refused["ok"] as? Bool == false else { throw Failure("'\(label)' was not refused: \(refused)") }
        }
        guard approvals.isEmpty else { throw Failure("A refused element still reached the approval prompt.") }
        pass("5B.1 policy: disabled button and password field refused before any approval prompt (submit and link are 5B.4 kinds).")

        // Element changes while the approval is open: refused, nothing clicked.
        decide = { approval in
            Task { @MainActor in
                _ = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "rename.textContent = 'Renamed'"])
                tools.resolve(id: approval.id, allow: true)
            }
        }
        let renamed = try await click(try elementID(map, "Rename me"))
        map = try await elements()
        guard renamed["ok"] as? Bool == false, map["Rename clicks: 0"] != nil else {
            throw Failure("Click on an element changed during approval was not refused: \(renamed)")
        }
        pass("5B.1 element changed during approval: refused, nothing clicked (\(renamed["error"] as? String ?? "")).")

        // Covered by an invisible overlay: refused by hit test, nothing clicked.
        decide = { tools.resolve(id: $0.id, allow: true) }
        let covered = try await click(try elementID(map, "Covered button"))
        map = try await elements()
        guard covered["ok"] as? Bool == false, map["Covered clicks: 0"] != nil else {
            throw Failure("Click on a covered element was not refused: \(covered)")
        }
        pass("5B.1 hidden overlay: hit test refused the click, nothing clicked (\(covered["error"] as? String ?? "")).")

        // Page reloads while the approval is open: refused.
        let counterBeforeReload = try elementID(map, "Clicked 1 times")
        decide = { approval in
            Task { @MainActor in
                _ = try? await devtoolsC.call(pageC, "Page.reload")
                _ = try? await waitUntil("reload during approval", timeout: 10) {
                    guard let r = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "document.getElementById('counter').textContent", "returnByValue": true]),
                          let text = (r["result"] as? [String: Any])?["value"] as? String else { return false }
                    return text == "Clicked 0 times"
                }
                tools.resolve(id: approval.id, allow: true)
            }
        }
        let reloaded = try await click(counterBeforeReload)
        guard reloaded["ok"] as? Bool == false else { throw Failure("Click after reload during approval was not refused: \(reloaded)") }
        map = try await elements()
        guard map["Clicked 0 times"] != nil else { throw Failure("Reloaded page shows a click: \(map.keys.sorted()).") }
        pass("5B.1 page reloaded during approval: refused, nothing clicked (\(reloaded["error"] as? String ?? "")).")

        // An element reference from the previous document is never valid.
        approvals = []
        let stale = try await click(counterBeforeReload)
        guard stale["ok"] as? Bool == false, approvals.isEmpty else { throw Failure("Stale element reference was accepted: \(stale)") }
        pass("5B.1 stale element reference from the previous document refused before approval.")

        // 5B.2. Safe text entry through the production tool, approval, and bridge.
        let beforeType = await {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "performance.timeOrigin", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? Double else { return 0.0 }
            return value
        }()
        try await devtoolsC.call(pageC, "Page.navigate", ["url": base + "/type"])
        _ = try await waitUntil("type fixture to load", timeout: 10) {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate",
                      ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? String else { return false }
            let parts = value.split(separator: "|")
            return parts.count == 2 && Double(parts[0]) != beforeType && parts[1] == "complete"
        }
        _ = try await readUntil("type fixture read", id: tabC) { $0.title == "Halo Type Fixture" }
        func type(_ id: String, _ text: String) async throws -> [String: Any] {
            try await run("type_in_browser_field", ["tab_id": tabC, "element_id": id, "text": text])
        }

        map = try await elements()
        // Password and one-time-code fields are both protected; their labels are withheld.
        for (label, typable) in [("Search query", true), ("Notes", true), ("Rename field", true), ("(protected)", false),
                                 ("(protected) #2", false), ("Card number", false), ("Read only field", false), ("Disabled field", false)] {
            guard map[label]?["typable"] as? Bool == typable else {
                throw Failure("Field '\(label)' typable flag should be \(typable); got \(String(describing: map[label])).")
            }
        }
        pass("5B.2 observation: plain text fields typable; password, one-time-code, payment, read-only, and disabled fields are not.")

        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let typed = try await type(try elementID(map, "Search query"), "hello halo")
        map = try await elements()
        guard typed["ok"] as? Bool == true, typed["verified"] as? Bool == true,
              let typePreview = approvals.first, approvals.count == 1,
              typePreview.path.contains("Halo Type Fixture"), typePreview.preview.contains("Search query"), typePreview.preview.contains("hello halo"),
              map["Query length: 10"] != nil, map["Query input trusted: yes"] != nil, map["Form submissions: 0"] != nil else {
            throw Failure("Approved typing failed: \(typed) preview=\(String(describing: approvals.first)) page=\(map.keys.sorted())")
        }
        pass("5B.2 approved typing: preview showed site, field, and exact text; genuine input landed and was verified without reading the field; nothing submitted.")

        let replaced = try await type(try elementID(map, "Search query"), "second")
        let note = try await type(try elementID(map, "Notes"), "a short note")
        map = try await elements()
        guard replaced["verified"] as? Bool == true, note["verified"] as? Bool == true,
              map["Query length: 6"] != nil, map["Notes length: 12"] != nil, map["Form submissions: 0"] != nil else {
            throw Failure("Replacement or textarea typing failed: \(replaced) \(note) page=\(map.keys.sorted())")
        }
        pass("5B.2 replacement: typing replaced the field's previous text; textarea entry verified; still no submission.")

        decide = { tools.resolve(id: $0.id, allow: false) }
        let deniedType = try await type(try elementID(map, "Search query"), "should not appear")
        map = try await elements()
        guard deniedType["denied"] as? Bool == true, map["Query length: 6"] != nil else {
            throw Failure("Denied typing changed the field: \(deniedType)")
        }
        pass("5B.2 denied typing: nothing typed.")

        approvals = []
        for label in ["(protected)", "(protected) #2", "Card number", "Read only field", "Disabled field"] {
            let refused = try await type(try elementID(map, label), "hello")
            guard refused["ok"] as? Bool == false else { throw Failure("Field '\(label)' was not refused: \(refused)") }
        }
        for text in ["line one\nline two", "tab\tseparated", "sk-abcdefghijklmnopqrstuvwxyz012345", "4111 1111 1111 1111",
                     "-----BEGIN PRIVATE KEY-----", ""] {
            let refused = try await type(try elementID(map, "Search query"), text)
            guard refused["ok"] as? Bool == false else { throw Failure("Text '\(text.prefix(12))' was not refused: \(refused)") }
        }
        map = try await elements()
        guard approvals.isEmpty, map["Query length: 6"] != nil, map["Form submissions: 0"] != nil else {
            throw Failure("A refused field or text reached approval or changed the page.")
        }
        pass("5B.2 policy: password, one-time-code, card, read-only, and disabled fields, and line breaks, tabs, keys, card numbers, and empty text, refused before any approval prompt.")

        decide = { approval in
            Task { @MainActor in
                _ = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "document.querySelector('label[for=rn]').textContent = 'Renamed field'"])
                tools.resolve(id: approval.id, allow: true)
            }
        }
        let relabeled = try await type(try elementID(map, "Rename field"), "hello")
        map = try await elements()
        guard relabeled["ok"] as? Bool == false, map["Rename field length: 0"] != nil else {
            throw Failure("Typing into a field relabeled during approval was not refused: \(relabeled)")
        }
        pass("5B.2 field changed during approval: refused, nothing typed (\(relabeled["error"] as? String ?? "")).")

        decide = { approval in
            Task { @MainActor in
                _ = try? await devtoolsC.call(pageC, "Page.reload")
                _ = try? await waitUntil("reload during typing approval", timeout: 10) {
                    guard let r = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "document.readyState + '|' + q.value.length", "returnByValue": true]),
                          let text = (r["result"] as? [String: Any])?["value"] as? String else { return false }
                    return text == "complete|0"
                }
                tools.resolve(id: approval.id, allow: true)
            }
        }
        let reloadedType = try await type(try elementID(map, "Search query"), "after reload")
        map = try await elements()
        guard reloadedType["ok"] as? Bool == false, map["Query length: 0"] != nil else {
            throw Failure("Typing after a reload during approval was not refused: \(reloadedType)")
        }
        pass("5B.2 page reloaded during approval: refused, nothing typed (\(reloadedType["error"] as? String ?? "")).")

        // 5B.3. Select, scroll, and navigation through the production tools.
        let beforeSelect = await {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "performance.timeOrigin", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? Double else { return 0.0 }
            return value
        }()
        try await devtoolsC.call(pageC, "Page.navigate", ["url": base + "/select"])
        _ = try await waitUntil("select fixture to load", timeout: 10) {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate",
                      ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? String else { return false }
            let parts = value.split(separator: "|")
            return parts.count == 2 && Double(parts[0]) != beforeSelect && parts[1] == "complete"
        }
        _ = try await readUntil("select fixture read", id: tabC) { $0.title == "Halo Select Fixture" }

        map = try await elements()
        guard map["Size"]?["selectable"] as? Bool == true, map["Size"]?["options"] as? [String] == ["Small", "Medium", "Large"],
              map["Message list"]?["scrollable"] as? Bool == true,
              ["Toppings", "Locked choice", "Expiry month"].allSatisfy({ map[$0] != nil && map[$0]?["selectable"] == nil }) else {
            throw Failure("5B.3 flags wrong: \(map.filter { ["Size", "Toppings", "Locked choice", "Expiry month", "Message list"].contains($0.key) })")
        }
        pass("5B.3 observation: single-choice dropdown selectable with its enabled options; multi-select, disabled, and card-expiry dropdowns are not; scrollable region reported.")

        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let selected = try await run("select_browser_option", ["tab_id": tabC, "element_id": try elementID(map, "Size"), "option": "Large"])
        map = try await elements()
        guard selected["verified"] as? Bool == true, let selectPreview = approvals.first,
              selectPreview.preview.contains("Size"), selectPreview.preview.contains("Large"),
              map["Size: Large"] != nil, map["Form submissions: 0"] != nil else {
            throw Failure("Approved selection failed: \(selected) page=\(map.keys.sorted())")
        }
        pass("5B.3 approved selection: preview named the dropdown and option; option selected and verified; nothing submitted.")

        approvals = []
        var refusals: [[String: Any]] = [
            try await run("select_browser_option", ["tab_id": tabC, "element_id": try elementID(map, "Size"), "option": "Huge"])
        ]
        for label in ["Toppings", "Locked choice", "Expiry month"] {
            refusals.append(try await run("select_browser_option", ["tab_id": tabC, "element_id": try elementID(map, label), "option": "Cheese"]))
        }
        decide = { tools.resolve(id: $0.id, allow: false) }
        let deniedSelect = try await run("select_browser_option", ["tab_id": tabC, "element_id": try elementID(map, "Size"), "option": "Medium"])
        map = try await elements()
        guard refusals.allSatisfy({ $0["ok"] as? Bool == false }), approvals.count == 1,
              deniedSelect["denied"] as? Bool == true, map["Size: Large"] != nil else {
            throw Failure("Selection refusals or denial failed: \(refusals) \(deniedSelect)")
        }
        pass("5B.3 selection policy: disabled option and multi-select, disabled, and card-expiry dropdowns refused before approval; denial changed nothing.")

        decide = { approval in
            Task { @MainActor in
                _ = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "document.querySelector('label[for=rsel]').textContent = 'Renamed dropdown'"])
                tools.resolve(id: approval.id, allow: true)
            }
        }
        let relabeledSelect = try await run("select_browser_option", ["tab_id": tabC, "element_id": try elementID(map, "Rename dropdown"), "option": "Two"])
        map = try await elements()
        guard relabeledSelect["ok"] as? Bool == false, map["Rename dropdown: One"] != nil else {
            throw Failure("Selection on a dropdown changed during approval was not refused: \(relabeledSelect)")
        }
        pass("5B.3 dropdown changed during approval: refused, nothing selected (\(relabeledSelect["error"] as? String ?? "")).")

        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let pageScroll = try await run("scroll_browser_tab", ["tab_id": tabC, "direction": "down", "amount": 3])
        map = try await elements()
        guard pageScroll["verified"] as? Bool == true, approvals.first?.preview.contains("the page down by 3 steps") == true,
              map["Page scrolled: yes"] != nil, map["List scrolled: no"] != nil else {
            throw Failure("Page scroll failed: \(pageScroll) page=\(map.keys.sorted())")
        }
        let listScroll = try await run("scroll_browser_tab", ["tab_id": tabC, "direction": "down", "amount": 2,
                                                              "element_id": try elementID(map, "Message list")])
        map = try await elements()
        guard listScroll["verified"] as? Bool == true, map["List scrolled: yes"] != nil else {
            throw Failure("Region scroll failed: \(listScroll) page=\(map.keys.sorted())")
        }
        pass("5B.3 scrolling: genuine wheel scrolled the page, then the named region; both verified by position change.")

        approvals = []
        var badURLs: [[String: Any]] = []
        for url in ["javascript:alert(1)", "file:///etc/passwd", "http://user:pw@127.0.0.1/", "data:text/html,hi", "not a url", "ftp://127.0.0.1/"] {
            badURLs.append(try await run("navigate_browser_tab", ["tab_id": tabC, "url": url]))
        }
        decide = { tools.resolve(id: $0.id, allow: false) }
        let deniedNav = try await run("navigate_browser_tab", ["tab_id": tabC, "url": base + "/page-b"])
        let stillSelect = try await service.readTab(id: tabC)
        guard badURLs.allSatisfy({ $0["ok"] as? Bool == false }), approvals.count == 1,
              deniedNav["denied"] as? Bool == true, stillSelect.title == "Halo Select Fixture" else {
            throw Failure("Navigation refusals or denial failed: \(badURLs) \(deniedNav)")
        }
        pass("5B.3 navigation policy: javascript:, file:, data:, ftp:, credential, and invalid addresses refused before approval; denial stayed on the page.")

        let staleSize = try elementID(map, "Size")
        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let sameSite = try await run("navigate_browser_tab", ["tab_id": tabC, "url": base + "/page-b"])
        guard sameSite["ok"] as? Bool == true, sameSite["still_authorized"] as? Bool == true,
              let navPreview = approvals.first, navPreview.preview.contains("From: \(base)/select"), navPreview.preview.contains("To: \(base)/page-b"),
              !navPreview.preview.contains("leaves") else {
            throw Failure("Same-site navigation failed: \(sameSite) preview=\(String(describing: approvals.first))")
        }
        _ = try await readUntil("page B after navigation", id: tabC) { $0.title == "Halo Fixture Page B" }
        approvals = []
        let staleSelect = try await run("select_browser_option", ["tab_id": tabC, "element_id": staleSize, "option": "Small"])
        guard staleSelect["ok"] as? Bool == false, approvals.isEmpty else {
            throw Failure("Element reference from before navigation was accepted: \(staleSelect)")
        }
        pass("5B.3 same-site navigation: preview showed exact From/To; tab stayed authorized; old element references invalid.")

        let crossSite = try await run("navigate_browser_tab", ["tab_id": tabC, "url": "http://localhost:\(fixture.port)/halo-test"])
        guard crossSite["ok"] as? Bool == true, crossSite["still_authorized"] as? Bool == false,
              approvals.first?.preview.contains("This leaves 127.0.0.1") == true, await !service.isAuthorized(tabID: tabC) else {
            throw Failure("Cross-site navigation failed: \(crossSite) preview=\(String(describing: approvals.first))")
        }
        pass("5B.3 cross-site navigation: approval warned it leaves the site; access to the tab ended after loading.")

        // A site Chrome does not grant the extension keeps the normal read path
        // while the bridge is connected; actions there are refused with a reason.
        guard let uncovered = controller.announcements.first(where: { $0.url.hasPrefix(uncoveredBase) }) else {
            throw Failure("The restricted-site tab was not announced.")
        }
        runtime.setReadResponse(id: uncovered.tabID, title: "Halo Disposable Browser Fixture", url: uncovered.url, text: "Restricted site text")
        try await authorize(uncovered.tabID, url: uncovered.url)
        let outsideRead = try await service.readTab(id: uncovered.tabID)
        let outsideClick = try await run("click_browser_element", ["tab_id": uncovered.tabID, "element_id": "el_1_ab"])
        let outsideScroll = try await run("scroll_browser_tab", ["tab_id": uncovered.tabID, "direction": "down"])
        guard outsideRead.content == "Restricted site text", outsideRead.elements.isEmpty, await service.activeBridgeServer() != nil,
              (outsideClick["error"] as? String)?.contains("Site access") == true,
              (outsideScroll["error"] as? String)?.contains("Site access") == true else {
            throw Failure("Restricted-site handling failed: read=\(outsideRead.content) click=\(outsideClick) scroll=\(outsideScroll)")
        }
        pass("Site access: on a site Chrome withholds from the extension, Halo still reads via the normal path and refuses actions, pointing to Chrome's Site access setting.")

        // 5B.4. Sensitive-action policy: blocked families, ordinary form
        // submission, and following links.
        let beforeForms = await {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "performance.timeOrigin", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? Double else { return 0.0 }
            return value
        }()
        try await devtoolsC.call(pageC, "Page.navigate", ["url": base + "/forms"])
        _ = try await waitUntil("forms fixture to load", timeout: 10) {
            guard let result = try? await devtoolsC.call(pageC, "Runtime.evaluate",
                      ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                  let value = (result["result"] as? [String: Any])?["value"] as? String else { return false }
            let parts = value.split(separator: "|")
            return parts.count == 2 && Double(parts[0]) != beforeForms && parts[1] == "complete"
        }
        try await authorize(tabC, url: base + "/forms", title: "Halo Forms Fixture")
        _ = try await readUntil("forms fixture read", id: tabC) { $0.title == "Halo Forms Fixture" }

        map = try await elements()
        let expectedKinds = ["Search": "submit", "Page B": "link", "Other site": "link"]
        let expectedBlocked = ["Continue": "password", "Continue to review": "payment", "Send": "send or publish",
                               "Upload": "uploads", "Next step": "different website", "Delete account": "account",
                               "Buy now": "payment", "Open in new tab": "new tab", "Download report": "downloads",
                               "Email us": "not a web link", "Sign out": "account"]
        for (label, kind) in expectedKinds where !(map[label]?["clickable"] as? Bool == true && map[label]?["click_kind"] as? String == kind) {
            throw Failure("'\(label)' should be a clickable \(kind); got \(String(describing: map[label])).")
        }
        for (label, phrase) in expectedBlocked {
            guard map[label]?["clickable"] as? Bool == false, (map[label]?["blocked"] as? String)?.contains(phrase) == true else {
                throw Failure("'\(label)' should be blocked (\(phrase)); got \(String(describing: map[label])).")
            }
        }
        pass("5B.4 classification: ordinary form submit and same-tab links clickable; sign-in, payment, account, message, upload, other-site form, new-tab, download, and non-web links blocked with their own reasons.")

        approvals = []
        for label in expectedBlocked.keys.sorted() {
            let refused = try await click(try elementID(map, label))
            guard refused["ok"] as? Bool == false, (refused["error"] as? String)?.hasPrefix("Blocked:") == true else {
                throw Failure("Blocked '\(label)' was not refused with its reason: \(refused)")
            }
        }
        guard approvals.isEmpty else { throw Failure("A blocked action reached the approval prompt.") }
        pass("5B.4 blocked families: all \(expectedBlocked.count) refused before any approval prompt, each with a specific reason.")

        decide = { tools.resolve(id: $0.id, allow: true) }
        _ = try await type(try elementID(map, "Search query"), "hello")
        map = try await elements()
        approvals = []
        let submitted = try await click(try elementID(map, "Search"))
        guard submitted["ok"] as? Bool == true, submitted["verified"] as? Bool == true, submitted["kind"] as? String == "submit",
              submitted["still_authorized"] as? Bool == true, let submitPreview = approvals.first,
              submitPreview.title == "Submit this form?", submitPreview.preview.contains("Sends to: 127.0.0.1 (this site)"),
              submitPreview.preview.contains("Search query — “hello” (typed by Halo)"),
              submitPreview.preview.contains("Category — filled (not shown)") else {
            throw Failure("Form submission failed: \(submitted) preview=\(String(describing: approvals.first))")
        }
        _ = try await readUntil("search results", id: tabC) { $0.content.contains("Last query: hello") }
        pass("5B.4 form submission: approval listed the destination and each field (Halo's own text shown, others only as filled/empty); trusted submit verified; results loaded.")

        map = try await elements()
        decide = { tools.resolve(id: $0.id, allow: false) }
        let deniedSubmit = try await click(try elementID(map, "Search"))
        let afterDenied = try await service.readTab(id: tabC)
        guard deniedSubmit["denied"] as? Bool == true, afterDenied.url.contains("q=hello") else {
            throw Failure("Denied submission changed the page: \(deniedSubmit)")
        }
        pass("5B.4 denied submission: nothing submitted.")

        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let followed = try await click(try elementID(map, "Page B"))
        guard followed["verified"] as? Bool == true, followed["kind"] as? String == "link", followed["still_authorized"] as? Bool == true,
              let linkPreview = approvals.first, linkPreview.title == "Follow this link?",
              linkPreview.preview.contains("To: \(base)/page-b"), !linkPreview.preview.contains("leaves") else {
            throw Failure("Following a same-site link failed: \(followed) preview=\(String(describing: approvals.first))")
        }
        _ = try await readUntil("page B via link", id: tabC) { $0.title == "Halo Fixture Page B" }
        pass("5B.4 same-site link: approval showed From/To; link followed and verified; access kept.")

        _ = try await run("navigate_browser_tab", ["tab_id": tabC, "url": base + "/forms"])
        _ = try await readUntil("forms again", id: tabC) { $0.title == "Halo Forms Fixture" }
        map = try await elements()
        approvals = []
        let leftSite = try await click(try elementID(map, "Other site"))
        guard leftSite["verified"] as? Bool == true, leftSite["still_authorized"] as? Bool == false,
              approvals.first?.preview.contains("This leaves 127.0.0.1") == true, await !service.isAuthorized(tabID: tabC) else {
            throw Failure("Cross-site link failed: \(leftSite) preview=\(String(describing: approvals.first))")
        }
        pass("5B.4 cross-site link: approval warned it leaves the site; followed; access to the tab ended.")

        // Real-page robustness: shadow DOM and crowded pages.
        func openFixture(_ path: String, title: String) async throws {
            let before = await {
                guard let r = try? await devtoolsC.call(pageC, "Runtime.evaluate", ["expression": "performance.timeOrigin", "returnByValue": true]),
                      let v = (r["result"] as? [String: Any])?["value"] as? Double else { return 0.0 }
                return v
            }()
            try await devtoolsC.call(pageC, "Page.navigate", ["url": base + path])
            _ = try await waitUntil("\(path) to load", timeout: 10) {
                guard let r = try? await devtoolsC.call(pageC, "Runtime.evaluate",
                          ["expression": "performance.timeOrigin + '|' + document.readyState", "returnByValue": true]),
                      let v = (r["result"] as? [String: Any])?["value"] as? String else { return false }
                let parts = v.split(separator: "|")
                return parts.count == 2 && Double(parts[0]) != before && parts[1] == "complete"
            }
            try await authorize(tabC, url: base + path, title: title)
            _ = try await readUntil("\(path) read", id: tabC) { $0.title == title }
        }

        try await openFixture("/shadow", title: "Halo Shadow Fixture")
        map = try await elements()
        guard map["Shadow action"]?["clickable"] as? Bool == true, map["Shadow field"]?["typable"] as? Bool == true else {
            throw Failure("Shadow DOM controls were not observed: \(map.keys.sorted())")
        }
        decide = { tools.resolve(id: $0.id, allow: true) }
        let shadowClick = try await click(try elementID(map, "Shadow action"))
        let shadowType = try await type(try elementID(map, "Shadow field"), "inside shadow")
        map = try await elements()
        guard shadowClick["verified"] as? Bool == true, shadowType["verified"] as? Bool == true,
              map["Shadow clicks: 1"] != nil, map["Shadow field length: 13"] != nil else {
            throw Failure("Shadow DOM actions failed: \(shadowClick) \(shadowType) page=\(map.keys.sorted())")
        }
        pass("Shadow DOM: controls inside an open shadow root observed; genuine click and typing landed and were verified (deep hit test, composed path, deep focus).")

        try await openFixture("/crowded", title: "Halo Crowded Fixture")
        let crowdedRead = try await run("read_browser_tab", ["tab_id": tabC])
        let crowdedElements = parsePage(crowdedRead["page"] as? String ?? "")
        let crowdedLabels = crowdedElements.compactMap { $0["label"] as? String }
        guard crowdedElements.count <= 200, crowdedLabels.contains("Target action"),
              crowdedElements.first(where: { $0["label"] as? String == "Target action" })?["clickable"] as? Bool == true,
              !crowdedLabels.contains(where: { $0.hasPrefix("Hidden control") }),
              let firstOffscreen = crowdedLabels.firstIndex(where: { $0.hasPrefix("Below fold") }),
              let target = crowdedLabels.firstIndex(of: "Target action"), target < firstOffscreen else {
            throw Failure("Crowded page prioritisation failed: \(crowdedElements.count) elements, first labels \(crowdedLabels.prefix(6))")
        }
        pass("Crowded page: hidden controls skipped, on-screen controls listed first within the 200-element limit.")

        // Media: the page's main video, through the media API, with a granted
        // gesture where autoplay rules or full screen need one.
        let noMedia = try await run("browser_media", ["tab_id": tabC, "action": "play"])
        guard noMedia["ok"] as? Bool == false else { throw Failure("Media control succeeded on a page without media: \(noMedia)") }
        try await openFixture("/media", title: "Halo Media Fixture")
        func media(_ args: [String: Any]) async throws -> (result: [String: Any], state: [String: Any]) {
            var all = args; all["tab_id"] = tabC
            let result = try await run("browser_media", all)
            return (result, result["media"] as? [String: Any] ?? [:])
        }
        decide = { tools.resolve(id: $0.id, allow: true) }
        approvals = []
        let played = try await media(["action": "play"])
        guard played.result["verified"] as? Bool == true, played.state["paused"] as? Bool == false, approvals.count == 1,
              approvals.first?.preview.contains("Play") == true, approvals.first?.path.contains("Halo Media Fixture") == true else {
            throw Failure("Media play failed: \(played.result) approvals=\(approvals.map(\.preview))")
        }
        let skipped = try await media(["action": "seek", "seconds": 20])
        let volume = try await media(["action": "volume", "level": 0.3])
        let muted = try await media(["action": "mute"])
        let mediaPaused = try await media(["action": "pause"])
        guard skipped.result["verified"] as? Bool == true, (skipped.state["position_s"] as? Int ?? 0) >= 19,
              volume.result["verified"] as? Bool == true, volume.state["volume"] as? Double == 0.3,
              muted.state["muted"] as? Bool == true, mediaPaused.state["paused"] as? Bool == true else {
            throw Failure("Media seek/volume/mute/pause failed: \(skipped.result) \(volume.result) \(muted.result) \(mediaPaused.result)")
        }
        approvals = []
        let status = try await media(["action": "status"])
        decide = { tools.resolve(id: $0.id, allow: false) }
        let deniedPlay = try await media(["action": "play"])
        let afterDenial = try await media(["action": "status"])
        guard status.result["ok"] as? Bool == true, approvals.count == 1, deniedPlay.result["denied"] as? Bool == true,
              afterDenial.state["paused"] as? Bool == true else {
            throw Failure("Media status or denial failed: \(status.result) \(deniedPlay.result) \(afterDenial.result) approvals=\(approvals.count)")
        }
        decide = { tools.resolve(id: $0.id, allow: true) }
        let full = try await media(["action": "fullscreen"])
        let windowed = try await media(["action": "exit_fullscreen"])
        guard full.result["verified"] as? Bool == true, windowed.result["verified"] as? Bool == true else {
            throw Failure("Media full screen failed: \(full.result) \(windowed.result)")
        }
        pass("Media: play past autoplay rules, seek, volume, mute, pause, and full screen on the main video, each verified by its state; status needs no approval; a denied play changes nothing; a page without media fails.")

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
        print("PASS: Real Chromium bridge suite (5A lifecycle, 5B.1–5B.4 browser actions): \(results.count) stages verified end to end.")
    }
}

extension NativeChecks.AnnouncedTabsRuntime {
    var pidForChecks: pid_t { (try? resolveBrowserContext(nil).pid) ?? 0 }
}

extension NativeChecks {
    /// Final Phase 5A security validation: a stolen session token is not enough to
    /// impersonate the helper, and manifest installation never overwrites a
    /// manifest it does not own while rolling back its own partial writes.
    static func runBridgeSecurityValidationChecks(helperBinaryURL: URL, pinnedExtensionID: String) async throws {
        // 1. Impostor process holding the real auth token.
        let server = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
        let sessionData = try Data(contentsOf: server.directoryURL.appendingPathComponent(BridgeSessionConfig.sessionFileName))
        let session = try JSONDecoder().decode(BridgeSessionConfig.self, from: sessionData)
        let impostor = Process()
        impostor.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        impostor.arguments = ["-I", "-c", """
            import json, os, socket, struct, sys, time
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sys.argv[1])
            body = json.dumps({"authToken": sys.argv[2], "clientPID": os.getpid(), "origin": sys.argv[3]}).encode()
            s.sendall(struct.pack("<I", len(body)) + body)
            time.sleep(3)
            """, session.socketPath, session.authToken, "chrome-extension://\(pinnedExtensionID)/"]
        impostor.standardOutput = FileHandle.nullDevice
        impostor.standardError = FileHandle.nullDevice
        try impostor.run()
        var impostorRejected = false
        do {
            try await server.acceptConnection(timeoutSeconds: 10)
        } catch let error as BridgeErrorDetails where error.code == .authenticationFailed {
            impostorRejected = true
        } catch {}
        let impostorAttached = await server.isConnected
        terminateProcessBounded(impostor)
        await server.close()
        guard impostorRejected, !impostorAttached else {
            throw Failure("Security validation: a non-Halo process holding the real session token was not rejected.")
        }

        // 2. Installer refuses a foreign manifest and rolls back its own writes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-installer-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dirs = ["first", "foreign", "third"].map { root.appendingPathComponent($0, isDirectory: true) }
        for dir in dirs { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let hostName = BrowserBridgeController.hostName
        let foreignFile = dirs[1].appendingPathComponent("\(hostName).json")
        let foreignBytes = Data(#"{"name":"app.halo.browser_bridge","path":"/usr/bin/true","type":"stdio","allowed_origins":["chrome-extension://someoneelse/"]}"#.utf8)
        try foreignBytes.write(to: foreignFile)
        let origins = ["chrome-extension://\(pinnedExtensionID)/"]
        var refused = false
        do {
            _ = try NativeMessagingInstaller.install(hostName: hostName, launcherPath: "/bin/sh", allowedOrigins: origins, targetDirectories: dirs)
        } catch {
            refused = true
        }
        let leftovers = [dirs[0], dirs[2]].filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("\(hostName).json").path) }
        guard refused, leftovers.isEmpty, (try? Data(contentsOf: foreignFile)) == foreignBytes else {
            throw Failure("Security validation: installer overwrote a foreign manifest or left partial manifests behind.")
        }

        // 3. Abandoned Halo manifests are recoverable; live ones are not.
        let abandonedDir = root.appendingPathComponent("abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandonedDir, withIntermediateDirectories: true)
        let deadLauncher = FileManager.default.temporaryDirectory
            .appendingPathComponent("hb_\(BridgeSocketIO.generateRandomHex(byteCount: 8))/halo_host_launcher.sh")
        let abandoned = try JSONSerialization.data(withJSONObject: ["name": hostName, "path": deadLauncher.path, "type": "stdio", "allowed_origins": origins])
        try abandoned.write(to: abandonedDir.appendingPathComponent("\(hostName).json"))
        let replaced = try NativeMessagingInstaller.install(hostName: hostName, launcherPath: "/bin/sh", allowedOrigins: origins, targetDirectories: [abandonedDir])
        NativeMessagingInstaller.uninstall(manifestURLs: replaced)

        let liveServer = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
        defer { Task { await liveServer.close() } }
        let liveDir = root.appendingPathComponent("live", isDirectory: true)
        let liveBytes = try JSONSerialization.data(withJSONObject: ["name": hostName, "path": liveServer.launcherURL!.path, "type": "stdio", "allowed_origins": origins])
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try liveBytes.write(to: liveDir.appendingPathComponent("\(hostName).json"))
        var liveRefused = false
        do {
            _ = try NativeMessagingInstaller.install(hostName: hostName, launcherPath: "/bin/sh", allowedOrigins: origins, targetDirectories: [liveDir])
        } catch {
            liveRefused = true
        }
        guard replaced.count == 1, liveRefused,
              (try? Data(contentsOf: liveDir.appendingPathComponent("\(hostName).json"))) == liveBytes else {
            throw Failure("Security validation: abandoned-manifest recovery replaced a live session or failed to recover a dead one.")
        }

        print("PASS: Phase 5A security validation: stolen session token rejected for a non-Halo process; installer refused a foreign manifest and rolled back partial writes; only abandoned Halo manifests are recoverable.")
    }
}

extension NativeChecks {
    /// Deterministic Phase 5B.1 protocol checks: malformed click requests and
    /// mismatched click results fail closed before reaching the browser or Halo.
    static func clickProtocolChecks() async throws {
        let nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let browser = BrowserIdentity(bundleID: "org.chromium.Chromium", sessionID: "7:click", pid: 7)
        let tab = TabGenerationIdentity(browser: browser, tabID: 5, documentGenerationID: 3, url: "http://127.0.0.1/click", domain: "127.0.0.1")
        let otherTab = TabGenerationIdentity(browser: browser, tabID: 6, documentGenerationID: 3, url: "http://127.0.0.1/click", domain: "127.0.0.1")
        let fingerprint = BridgeElementFingerprint(tagName: "button", role: "", label: "Clicked 0 times")
        func rejects(_ what: String, _ request: BridgeRequest) throws {
            do { _ = try BridgeMessageFraming.encode(request) } catch { return }
            throw Failure("Click protocol: \(what) was accepted.")
        }
        let valid = BridgeRequest(requestID: "click_ok", sessionNonce: nonce, type: .clickElement, targetTab: tab,
                                  elementID: "el_3_0011aabbccddeeff", expectedElement: fingerprint)
        _ = try BridgeMessageFraming.encode(valid)
        try rejects("click without fingerprint", BridgeRequest(requestID: "c1", sessionNonce: nonce, type: .clickElement, targetTab: tab, elementID: "el_3_ab"))
        try rejects("click without element", BridgeRequest(requestID: "c2", sessionNonce: nonce, type: .clickElement, targetTab: tab, expectedElement: fingerprint))
        try rejects("click without tab", BridgeRequest(requestID: "c3", sessionNonce: nonce, type: .clickElement, elementID: "el_3_ab", expectedElement: fingerprint))
        for bad in ["button#counter", "el_3_<script>", "EL_3_AB", "el_" + String(repeating: "a", count: 200)] {
            try rejects("element reference \(bad.prefix(20))", BridgeRequest(requestID: "c4", sessionNonce: nonce, type: .clickElement,
                                                                         targetTab: tab, elementID: bad, expectedElement: fingerprint))
        }
        try rejects("element fields on an observe request", BridgeRequest(requestID: "c5", sessionNonce: nonce, type: .observeTab,
                                                                         targetTab: tab, elementID: "el_3_ab", expectedElement: fingerprint))

        // A click result must be for the tab and document of the outstanding request.
        let validator = BridgeSessionValidator(sessionNonce: nonce)
        try await validator.authorizeTab(tab)
        try await validator.authorizeTab(otherTab)
        try await validator.validateRequest(valid)
        let mismatched = BridgeResponse(requestID: "click_ok", sessionNonce: nonce, success: true,
                                        actionResult: BridgeActionResult(tab: otherTab, elementID: "el_3_0011aabbccddeeff", performed: true))
        do {
            try await validator.validateResponse(mismatched)
            throw Failure("Click protocol: a click result for a different tab was accepted.")
        } catch let error as BridgeErrorDetails where error.code == .browserMismatch {}
        print("PASS: Phase 5B.1 click protocol: incomplete or malformed click requests, element fields on observe, and mismatched click results fail closed.")

        // Phase 5B.2: text travels only in typeText, single-line and bounded.
        let typeOK = BridgeRequest(requestID: "type_ok", sessionNonce: nonce, type: .typeText, targetTab: tab,
                                   elementID: "el_3_0011aabbccddeeff", expectedElement: fingerprint, text: "hello")
        _ = try BridgeMessageFraming.encode(typeOK)
        try rejects("typeText without text", BridgeRequest(requestID: "t1", sessionNonce: nonce, type: .typeText, targetTab: tab,
                                                           elementID: "el_3_ab", expectedElement: fingerprint))
        for bad in ["", "line\nbreak", "tab\there", "nul\u{0}", "sep\u{2028}", String(repeating: "a", count: 4_001)] {
            try rejects("typeText with unsafe text", BridgeRequest(requestID: "t2", sessionNonce: nonce, type: .typeText, targetTab: tab,
                                                                   elementID: "el_3_ab", expectedElement: fingerprint, text: bad))
        }
        try rejects("text on a click", BridgeRequest(requestID: "t3", sessionNonce: nonce, type: .clickElement, targetTab: tab,
                                                     elementID: "el_3_ab", expectedElement: fingerprint, text: "hi"))
        try rejects("text on an observe", BridgeRequest(requestID: "t4", sessionNonce: nonce, type: .observeTab, targetTab: tab, text: "hi"))

        // Halo's own text policy, applied before any approval prompt.
        let allowed = ["hello halo", "Order #12345 for Jane", "https://example.com/docs", "Café crème — 2 cups", "1234 5678"]
        let refusedTexts = ["a\nb", "sk-abcdefghijklmnopqrstuvwxyz", "AKIAABCDEFGHIJKLMNOP", "ghp_" + String(repeating: "a1", count: 18),
                            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.sig", "4111 1111 1111 1111", "5555-5555-5555-4444",
                            "-----BEGIN RSA PRIVATE KEY-----", "Zx9" + String(repeating: "k3Q", count: 14)]
        guard allowed.allSatisfy({ ChromeBrowserService.textRefusal($0) == nil }) else {
            throw Failure("Text policy refused ordinary text: \(allowed.filter { ChromeBrowserService.textRefusal($0) != nil })")
        }
        guard refusedTexts.allSatisfy({ ChromeBrowserService.textRefusal($0) != nil }) else {
            throw Failure("Text policy allowed secret-like text: \(refusedTexts.filter { ChromeBrowserService.textRefusal($0) == nil })")
        }
        print("PASS: Phase 5B.2 text protocol and policy: unsafe text rejected on the wire; keys, tokens, card numbers, and line breaks refused before approval; ordinary text allowed.")

        // Phase 5B.3: each action carries only its own fields, within bounds.
        _ = try BridgeMessageFraming.encode(BridgeRequest(requestID: "s_ok", sessionNonce: nonce, type: .selectOption, targetTab: tab,
                                                          elementID: "el_3_ab", expectedElement: fingerprint, option: "Large"))
        _ = try BridgeMessageFraming.encode(BridgeRequest(requestID: "sc_ok", sessionNonce: nonce, type: .scrollTab, targetTab: tab,
                                                          scroll: BridgeScroll(direction: .down, amount: 3)))
        _ = try BridgeMessageFraming.encode(BridgeRequest(requestID: "n_ok", sessionNonce: nonce, type: .navigateTab, targetTab: tab,
                                                          url: "https://example.com/docs?q=1"))
        try rejects("select without option", BridgeRequest(requestID: "s1", sessionNonce: nonce, type: .selectOption, targetTab: tab,
                                                           elementID: "el_3_ab", expectedElement: fingerprint))
        try rejects("option on a click", BridgeRequest(requestID: "s2", sessionNonce: nonce, type: .clickElement, targetTab: tab,
                                                       elementID: "el_3_ab", expectedElement: fingerprint, option: "x"))
        for amount in [0, 21, -1] {
            try rejects("scroll amount \(amount)", BridgeRequest(requestID: "sc1", sessionNonce: nonce, type: .scrollTab, targetTab: tab,
                                                                 scroll: BridgeScroll(direction: .down, amount: amount)))
        }
        try rejects("scroll with text", BridgeRequest(requestID: "sc2", sessionNonce: nonce, type: .scrollTab, targetTab: tab,
                                                      text: "hi", scroll: BridgeScroll(direction: .up, amount: 1)))
        try rejects("navigation with an element", BridgeRequest(requestID: "n1", sessionNonce: nonce, type: .navigateTab, targetTab: tab,
                                                                elementID: "el_3_ab", expectedElement: fingerprint, url: "https://example.com/"))
        for url in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pw@example.com/", "data:text/html,x", "example.com", "https://exa mple.com/"] {
            try rejects("navigation to \(url)", BridgeRequest(requestID: "n2", sessionNonce: nonce, type: .navigateTab, targetTab: tab, url: url))
        }
        try rejects("url on an observe", BridgeRequest(requestID: "n3", sessionNonce: nonce, type: .observeTab, targetTab: tab, url: "https://example.com/"))

        // Media control: one command, a value only where it belongs, no element.
        for media in [BridgeMedia(command: .pause), BridgeMedia(command: .seek, value: -10), BridgeMedia(command: .volume, value: 0.5),
                      BridgeMedia(command: .exitFullscreen)] {
            _ = try BridgeMessageFraming.encode(BridgeRequest(requestID: "m_ok", sessionNonce: nonce, type: .mediaControl, targetTab: tab, media: media))
        }
        for (label, media) in [("seek 0", BridgeMedia(command: .seek, value: 0)), ("seek 2 h", BridgeMedia(command: .seek, value: 7_200)),
                               ("seek without seconds", BridgeMedia(command: .seek)), ("volume 1.5", BridgeMedia(command: .volume, value: 1.5)),
                               ("play with a value", BridgeMedia(command: .play, value: 1))] {
            try rejects("media \(label)", BridgeRequest(requestID: "m1", sessionNonce: nonce, type: .mediaControl, targetTab: tab, media: media))
        }
        try rejects("media without a command", BridgeRequest(requestID: "m2", sessionNonce: nonce, type: .mediaControl, targetTab: tab))
        try rejects("media with an element", BridgeRequest(requestID: "m3", sessionNonce: nonce, type: .mediaControl, targetTab: tab,
                                                           elementID: "el_3_ab", expectedElement: fingerprint, media: BridgeMedia(command: .play)))
        try rejects("media on a click", BridgeRequest(requestID: "m4", sessionNonce: nonce, type: .clickElement, targetTab: tab,
                                                      elementID: "el_3_ab", expectedElement: fingerprint, media: BridgeMedia(command: .play)))
        guard ChromeBrowserService.navigationRefusal("https://example.com/a?b=c#d") == nil,
              ["javascript:alert(1)", "file:///x", "http://u:p@h/", "ftp://h/", "nope"].allSatisfy({ ChromeBrowserService.navigationRefusal($0) != nil }) else {
            throw Failure("Navigation policy accepted an unsafe address or refused a normal one.")
        }
        // A navigation request's result survives its own navigation, but not a
        // pause in flight; any other request fails on any navigation.
        func navigationEvent(from generation: UInt64) -> TabNavigationEvent {
            TabNavigationEvent(browser: browser, tabID: 5, previousDocumentGenerationID: generation,
                               newDocumentGenerationID: generation + 1, newURL: "http://127.0.0.1/next", newDomain: "127.0.0.1")
        }
        func navigateRequest(_ id: String, generation: UInt64) -> BridgeRequest {
            BridgeRequest(requestID: id, sessionNonce: nonce, type: .navigateTab,
                          targetTab: TabGenerationIdentity(browser: browser, tabID: 5, documentGenerationID: generation,
                                                           url: "http://127.0.0.1/click", domain: "127.0.0.1"),
                          url: "http://127.0.0.1/next")
        }
        func result(_ request: BridgeRequest) -> BridgeResponse {
            BridgeResponse(requestID: request.requestID, sessionNonce: nonce, success: true,
                           actionResult: BridgeActionResult(tab: request.targetTab!, elementID: "el_page", performed: true))
        }
        let navValidator = BridgeSessionValidator(sessionNonce: nonce)
        try await navValidator.authorizeTab(tab)
        let nav1 = navigateRequest("nav1", generation: 3)
        try await navValidator.validateRequest(nav1)
        try await navValidator.notifyNavigation(event: navigationEvent(from: 3))
        try await navValidator.validateResponse(result(nav1))

        let nav2 = navigateRequest("nav2", generation: 4)
        try await navValidator.authorizeTab(nav2.targetTab!)
        try await navValidator.validateRequest(nav2)
        try await navValidator.notifyNavigation(event: navigationEvent(from: 4))
        await navValidator.setPaused(true)
        await navValidator.setPaused(false)
        do {
            try await navValidator.validateResponse(result(nav2))
            throw Failure("Navigation protocol: a navigation result survived a pause in flight.")
        } catch let error as BridgeErrorDetails where error.code == .accessPaused {}

        // Clicks may navigate (links, submissions), so their results survive
        // navigation too; observations never do.
        let clickTab = TabGenerationIdentity(browser: browser, tabID: 5, documentGenerationID: 5, url: "http://127.0.0.1/next", domain: "127.0.0.1")
        try await navValidator.authorizeTab(clickTab)
        let click5 = BridgeRequest(requestID: "click5", sessionNonce: nonce, type: .clickElement, targetTab: clickTab,
                                   elementID: "el_5_ab", expectedElement: fingerprint)
        try await navValidator.validateRequest(click5)
        try await navValidator.notifyNavigation(event: navigationEvent(from: 5))
        try await navValidator.validateResponse(BridgeResponse(requestID: "click5", sessionNonce: nonce, success: true,
                                                               actionResult: BridgeActionResult(tab: clickTab, elementID: "el_5_ab", performed: true)))
        let observeTab6 = TabGenerationIdentity(browser: browser, tabID: 5, documentGenerationID: 6, url: "http://127.0.0.1/next", domain: "127.0.0.1")
        try await navValidator.authorizeTab(observeTab6)
        let observe6 = BridgeRequest(requestID: "observe6", sessionNonce: nonce, type: .observeTab, targetTab: observeTab6)
        try await navValidator.validateRequest(observe6)
        try await navValidator.notifyNavigation(event: navigationEvent(from: 6))
        do {
            try await navValidator.validateResponse(BridgeResponse(requestID: "observe6", sessionNonce: nonce, success: true,
                                                                   observation: TabObservedEvent(tab: observeTab6, title: "t", elements: [])))
            throw Failure("Navigation protocol: an observation survived a navigation in flight.")
        } catch is BridgeErrorDetails {}
        print("PASS: Phase 5B.3 select/scroll/navigate protocol: each action carries only its own fields; scroll bounds and unsafe or credentialed addresses rejected; navigation and click results survive their own navigation but not a pause; observations never survive navigation.")

        // Phase 5B.4: Halo re-checks the extension's click classification.
        let rect = BoundedRect(x: 0, y: 0, width: 10, height: 10)
        func element(_ tag: String, kind: String?, reason: String? = nil, destination: String? = nil, actionable: Bool = false) -> ObservedDOMElement {
            ObservedDOMElement(elementID: "el_1_ab", tagName: tag, role: "", label: "x", isProtected: false, isEnabled: true,
                               bounds: rect, isActionable: actionable, actionKind: kind, blockedReason: reason, destinationURL: destination)
        }
        let kindCases: [(ObservedDOMElement, BridgeClickKind?)] = [
            (element("button", kind: "button", actionable: true), .button),
            (element("button", kind: "submit", destination: "http://127.0.0.1/forms?q=1"), .submit),
            (element("a", kind: "link", destination: "https://example.com/"), .link),
            (element("button", kind: "submit", destination: "https://example.com/collect"), nil),
            (element("button", kind: "submit", destination: nil), nil),
            (element("a", kind: "link", destination: "javascript:alert(1)"), nil),
            (element("a", kind: "button", actionable: true), nil),
            (element("div", kind: "link", destination: "https://example.com/"), nil),
            (element("button", kind: nil, reason: "payment", actionable: true), nil),
            (element("button", kind: "submit", destination: "http://127.0.0.1:9999/forms"), nil),
            (element("button", kind: "submit", destination: "https://127.0.0.1/forms"), nil)
        ]
        let page = "http://127.0.0.1/forms"
        for (index, (candidate, expected)) in kindCases.enumerated() where ChromeBrowserService.clickKind(candidate, pageURL: page) != expected {
            throw Failure("Click policy case \(index) classified as \(String(describing: ChromeBrowserService.clickKind(candidate, pageURL: page))), expected \(String(describing: expected)).")
        }
        guard ChromeBrowserService.clickKind(element("button", kind: "submit", destination: "https://www.youtube.com/results?search_query=x"),
                                             pageURL: "https://www.youtube.com/") == .submit else {
            throw Failure("A same-origin submission on a real site was not allowed.")
        }
        func observationRejected(_ candidate: ObservedDOMElement) -> Bool {
            let response = BridgeResponse(requestID: "obs", sessionNonce: nonce, success: true,
                                          observation: TabObservedEvent(tab: tab, title: "t", elements: [candidate]))
            return (try? BridgeMessageFraming.encode(response)) == nil
        }
        guard observationRejected(element("button", kind: "submit", reason: "payment")),
              observationRejected(element("button", kind: "teleport")),
              observationRejected(element("button", kind: nil, reason: "unknownFamily")) else {
            throw Failure("Observation with an inconsistent or unknown click classification was accepted.")
        }
        print("PASS: Phase 5B.4 click policy: Halo rejects other-site submissions, non-web or missing destinations, and kind/tag mismatches even if the extension reports them; inconsistent or unknown classifications fail on the wire.")
    }
}

extension NativeChecks {
    /// Browser selection is unambiguous, and the bridge's covered sites match
    /// the extension manifest exactly.
    static func browserSelectionAndCoverageChecks() throws {
        typealias Running = SystemBrowserRuntime.RunningBrowser
        let chrome = Running(bundleID: "com.google.Chrome", pid: 10, launched: 1)
        let brave = Running(bundleID: "com.brave.Browser", pid: 20, launched: 2)
        let chromeCopy = Running(bundleID: "com.google.Chrome", pid: 11, launched: 3)
        let finder = Running(bundleID: "com.apple.finder", pid: 30, launched: 0)
        func refuses(_ what: String, _ body: () throws -> Running) throws {
            if (try? body()) == nil { return }
            throw Failure("Browser selection: \(what) did not refuse.")
        }
        guard try SystemBrowserRuntime.choose(from: [finder, chrome], requested: nil, lastActive: nil) == chrome,
              try SystemBrowserRuntime.choose(from: [chrome, brave], requested: nil, lastActive: "com.brave.Browser") == brave,
              try SystemBrowserRuntime.choose(from: [chrome, brave], requested: "com.google.Chrome", lastActive: "com.brave.Browser") == chrome else {
            throw Failure("Browser selection picked the wrong browser.")
        }
        try refuses("two browsers, none recently used") { try SystemBrowserRuntime.choose(from: [chrome, brave], requested: nil, lastActive: nil) }
        try refuses("two copies of one browser") { try SystemBrowserRuntime.choose(from: [chrome, chromeCopy], requested: nil, lastActive: "com.google.Chrome") }
        try refuses("requested browser not running") { try SystemBrowserRuntime.choose(from: [chrome], requested: "com.brave.Browser", lastActive: nil) }
        try refuses("no browser") { try SystemBrowserRuntime.choose(from: [finder], requested: nil, lastActive: nil) }

        guard ChromeBrowserService.bridgeCovers("http://127.0.0.1:8080/a"), ChromeBrowserService.bridgeCovers("https://www.youtube.com/"),
              ChromeBrowserService.bridgeCovers("https://example.com/x?y=1"),
              !ChromeBrowserService.bridgeCovers("chrome://settings"), !ChromeBrowserService.bridgeCovers("file:///etc/passwd"),
              !ChromeBrowserService.bridgeCovers("ftp://example.com/") else {
            throw Failure("Bridge coverage matched the wrong addresses.")
        }
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/BrowserBridgeExtension/manifest.json")
        guard let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any],
              let hosts = manifest["host_permissions"] as? [String], Set(hosts) == Set(ChromeBrowserService.bridgeHostPermissions) else {
            throw Failure("Bridge coverage list does not match the extension manifest's host_permissions.")
        }
        print("PASS: Browser selection and bridge coverage: one browser or the most recently used one is chosen, ambiguous or duplicate browsers are refused, and the bridge covers exactly the extension's host permissions (all http and https sites).")
    }
}

extension NativeChecks {
    /// Parses read_browser_tab's compact `id · role · label · actions` lines
    /// back into fields for checks.
    static func parsePage(_ page: String) -> [[String: Any]] {
        page.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " · ")
            guard parts.count >= 4 else { return nil }
            let action = parts[parts.count - 1]
            var element: [String: Any] = ["id": parts[0], "role": parts[1],
                                          "label": parts[2..<(parts.count - 1)].joined(separator: " · "),
                                          "clickable": false, "typable": false]
            switch action {
            case "click": element["clickable"] = true
            case "submit": element["clickable"] = true; element["click_kind"] = "submit"
            case "follow": element["clickable"] = true; element["click_kind"] = "link"
            case "type": element["typable"] = true
            case "scroll": element["scrollable"] = true
            case let a where a.hasPrefix("choose: "):
                element["selectable"] = true
                element["options"] = a.dropFirst("choose: ".count).components(separatedBy: ", ")
            case let a where a.hasPrefix("blocked: "):
                element["blocked"] = String(a.dropFirst("blocked: ".count))
            default: break
            }
            return element
        }
    }
}
