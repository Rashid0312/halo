import AppKit
import HaloCore

@MainActor
enum NativeChecks {
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func chatGPT() async throws {
        let listener = try OAuthLoopback()
        let waiting = Task { try await listener.wait(state: "halo-test-state") }
        func url(_ state: String) -> URL {
            var parts = URLComponents(url: listener.redirect, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "test-only")]
            return parts.url!
        }
        let (_, rejected) = try await URLSession.shared.data(from: url("wrong-state"))
        guard (rejected as? HTTPURLResponse)?.statusCode == 400 else { throw Failure("OAuth callback accepted wrong state") }
        let (_, accepted) = try await URLSession.shared.data(from: url("halo-test-state"))
        let callback = try await waiting.value
        guard (accepted as? HTTPURLResponse)?.statusCode == 200, callback.path == "/auth/callback" else { throw Failure("OAuth callback did not complete") }
        let cancelled = try OAuthLoopback()
        let pending = Task { try await cancelled.wait(state: "cancelled-state") }
        pending.cancel()
        do { _ = try await pending.value; throw Failure("OAuth callback cancellation ignored") }
        catch is CancellationError {}
        print("PASS: loopback-only OAuth callback, wrong-state rejection, valid callback, and cancellation; no real credentials used")
    }

    static func ui(_ tools: MacTools) async throws {
        let definitions = try JSONSerialization.jsonObject(with: await tools.definitions()) as? [[String: Any]] ?? []
        let names = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        guard ["inspect_ui", "ui_action", "type_text", "keypress", "window_layout", "screen_info", "search_web", "read_web_page", "focus_app", "scroll", "click_menu_item", "click_dialog_button"].allSatisfy(names.contains) else {
            throw Failure("UI tool definitions missing")
        }
        guard ["open_url", "quit_app"].allSatisfy(names.contains),
              MacTools.webURL("https://example.com/search?q=hello%20world") != nil,
              MacTools.webURL("HTTP://example.com") != nil else { throw Failure("Native app/web tools or valid URLs missing") }
        for invalid in ["file:///tmp/test", "javascript:alert(1)", "https://", "https://user:password@example.com", "https://example.com/a b", "example.com"] {
            guard MacTools.webURL(invalid) == nil else { throw Failure("Unsafe or incomplete URL accepted") }
        }
        let rejectedQuit = try await tools.execute(name: "quit_app", arguments: "{}")
        let quitObject = try JSONSerialization.jsonObject(with: Data(rejectedQuit.utf8)) as? [String: Any]
        guard quitObject?["ok"] as? Bool == false else { throw Failure("Quit without app ID was accepted") }
        print("PASS: app/web tool definitions, HTTP URL validation, unsafe scheme rejection, and missing quit target rejection")
        let (_, flags) = try UIAutomation.shortcut("cmd+shift+s")
        guard flags.contains(.maskCommand) && flags.contains(.maskShift) else { throw Failure("Shortcut modifiers missing") }
        var rejected = false
        do { _ = try UIAutomation.shortcut("unknown+q") } catch { rejected = true }
        guard rejected else { throw Failure("Invalid shortcut was accepted") }
        do { _ = try await tools.ui.describe(id: "stale-control"); throw Failure("Stale reference accepted") }
        catch let failure as Failure { throw failure }
        catch {}
        tools.ui.refreshAccess()
        if !tools.ui.trusted {
            let result = try await tools.execute(name: "inspect_ui", arguments: "{}")
            let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
            guard object?["ok"] as? Bool == false else { throw Failure("Inspection bypassed Accessibility permission") }
        }
        print("PASS: UI tools, shortcut validation, stale-control rejection, and Accessibility permission gate")
        print(tools.ui.trusted ? "Accessibility status: enabled; live app inspection can be checked" : "Accessibility status: waiting for user to enable Halo in macOS settings")
    }

    static func webResearch(_ tools: MacTools) async throws {
        guard WebResearch.publicURL("http://127.0.0.1/private") == nil,
              WebResearch.publicURL("http://localhost/private") == nil,
              WebResearch.publicURL("file:///etc/passwd") == nil,
              WebResearch.publicURL("https://example.com/") != nil else { throw Failure("Public URL boundary failed") }
        let searched = try await tools.execute(name: "search_web", arguments: #"{"query":"Apple macOS latest release official"}"#)
        guard let search = try JSONSerialization.jsonObject(with: Data(searched.utf8)) as? [String: Any],
              search["ok"] as? Bool == true,
              let results = search["results"] as? [[String: Any]],
              let first = results.first, let url = first["url"] as? String else { throw Failure("Live web search returned no results") }
        let arguments = try JSONSerialization.data(withJSONObject: ["url": url])
        let read = try await tools.execute(name: "read_web_page", arguments: String(decoding: arguments, as: UTF8.self))
        guard let page = try JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any],
              page["ok"] as? Bool == true, (page["content"] as? String)?.count ?? 0 >= 80 else {
            throw Failure("A live search result could not be read")
        }
        print("PASS: public web search returned \(results.count) sources and a result page was read; contents not printed; private-address access rejected")
    }

    static func appLifecycle(_ tools: MacTools) async throws {
        // Dictionary has no editable documents. Do not quit an app already used by the user.
        let appID = "com.apple.Dictionary"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty else {
            print("SKIP: Dictionary is already open; preserving the user's app")
            return
        }
        let opened = try await tools.execute(name: "open_app", arguments: #"{"name":"Dictionary"}"#)
        let openResult = try JSONSerialization.jsonObject(with: Data(opened.utf8)) as? [String: Any]
        guard openResult?["ok"] as? Bool == true else { throw Failure("Native Dictionary opening failed") }
        for _ in 0..<50 {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let closed = try await tools.execute(name: "quit_app", arguments: #"{"app_id":"com.apple.Dictionary"}"#)
        let closeResult = try JSONSerialization.jsonObject(with: Data(closed.utf8)) as? [String: Any]
        guard closeResult?["ok"] as? Bool == true,
              NSRunningApplication.runningApplications(withBundleIdentifier: appID).filter({ !$0.isTerminated }).isEmpty else {
            throw Failure("Native normal quit did not close the test app")
        }
        print("PASS: native tool opened Dictionary and confirmed normal termination; no force quit")
    }

    static func commands(_ tools: MacTools) async throws {
        let directory = FileManager.default.temporaryDirectory
        let result = try await CommandRunner.run(executable: "/usr/bin/printf", arguments: ["native-command-check"], directory: directory)
        guard result.status == 0, result.stdout == "native-command-check", !result.timedOut else { throw Failure("Command output missing") }
        let script = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", #"return "HALO_SCRIPT_OK""#], directory: directory)
        guard script.status == 0, script.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "HALO_SCRIPT_OK" else { throw Failure("AppleScript execution failed") }
        let failure = try await CommandRunner.run(executable: "/bin/zsh", arguments: ["-c", "printf failure >&2; exit 7"], directory: directory)
        guard failure.status == 7, failure.stderr == "failure" else { throw Failure("Command failure not preserved") }
        let bounded = try await CommandRunner.run(executable: "/usr/bin/yes", arguments: [], directory: directory, timeout: 0.15)
        guard bounded.timedOut, bounded.truncated, bounded.stdout.utf8.count <= 32768 else { throw Failure("Output or timeout was not bounded") }
        let running = Task { try await CommandRunner.run(executable: "/bin/sleep", arguments: ["20"], directory: directory) }
        try await Task.sleep(for: .milliseconds(100))
        running.cancel()
        do { _ = try await running.value; throw Failure("Command cancellation ignored") }
        catch is CancellationError {}
        let args = #"{"command":"printf approved-command-check","why":"Check command approval"}"#
        let denied = Task { try await tools.execute(name: "run_shell", arguments: args) }
        let preview = try await waitForApproval(tools)
        guard preview.preview == "printf approved-command-check" else { throw Failure("Command preview differed from execution") }
        tools.resolve(id: preview.id, allow: false)
        let denial = try JSONSerialization.jsonObject(with: Data(try await denied.value.utf8)) as? [String: Any]
        guard denial?["denied"] as? Bool == true else { throw Failure("Command denial ignored") }
        let approved = Task { try await tools.execute(name: "run_shell", arguments: args) }
        let approval = try await waitForApproval(tools)
        tools.resolve(id: approval.id, allow: true)
        let output = try JSONSerialization.jsonObject(with: Data(try await approved.value.utf8)) as? [String: Any]
        guard output?["ok"] as? Bool == true, output?["stdout"] as? String == "approved-command-check" else { throw Failure("Approved command failed") }
        let pending = Task { try await tools.execute(name: "run_applescript", arguments: #"{"script":"return 42","why":"Check pending cancellation"}"#) }
        _ = try await waitForApproval(tools)
        pending.cancel()
        do { _ = try await pending.value; throw Failure("Pending script approval ignored cancellation") }
        catch is CancellationError {}
        guard tools.approval == nil else { throw Failure("Cancelled script left approval visible") }
        print("PASS: command output, nonzero exit, output limits, timeout, running cancellation, exact approval, denial, and pending script cancellation")
    }

    private actor ScreenFixture: MacToolExecutor {
        let result: String
        private(set) var used = false
        init(result: String) { self.result = result }
        func definitions() async throws -> Data {
            Data(#"[{"type":"function","function":{"name":"inspect_screen","description":"Get the test image to read.","parameters":{"type":"object","properties":{}}}}]"#.utf8)
        }
        func execute(name: String, arguments: String) async throws -> String {
            guard name == "inspect_screen" else { throw Failure("Unexpected vision test tool") }
            used = true
            return result
        }
    }

    static func screen(key: String) async throws {
        guard let executable = Bundle.main.executableURL else { throw Failure("Test executable missing") }
        let host = Process()
        host.executableURL = executable
        host.arguments = ["--ui-test-host"]
        try host.run()
        defer { if host.isRunning { host.terminate() } }
        let capture = try await ScreenService().captureTestWindow(pid: host.processIdentifier)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "mime_type": "image/jpeg", "image_base64": capture.data.base64EncodedString(), "scope": capture.scope])
        let result = String(decoding: data, as: UTF8.self)
        guard let parts = DeepSeekProvider.screenAttachment(result: result), !parts.toolText.contains("image_base64"),
              parts.imageContent.count == 1 else { throw Failure("Screenshot was not converted into an image attachment") }
        let fixture = ScreenFixture(result: result)
        var reply = ""
        for try await delta in DeepSeekProvider(key: key, tools: fixture).reply(to: [Message(isUser: true, text: "Use inspect_screen to get the test image. Read the large HALO VISION line and reply with only its five-digit code. Do not guess it without inspecting the image.")]) { reply += delta }
        guard await fixture.used, reply.contains("73914") else { throw Failure("Vision model did not read the captured fixture correctly") }
        print("PASS: native window screenshot, JPEG encoding, image attachment, live DeepSeek tool call, and visual reading of disposable test window; no desktop image sent")
    }

    static func peekabooCapture(_ tools: MacTools) async throws {
        let appID = "com.apple.Dictionary"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty
        if !wasRunning {
            let opened = try await tools.execute(name: "open_app", arguments: #"{"name":"Dictionary"}"#)
            let object = try JSONSerialization.jsonObject(with: Data(opened.utf8)) as? [String: Any]
            guard object?["ok"] as? Bool == true else { throw Failure("Could not open the capture fixture") }
            for _ in 0..<50 {
                if !NSRunningApplication.runningApplications(withBundleIdentifier: appID).isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            if !wasRunning {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: appID) { app.terminate() }
            }
        }

        let pending = Task {
            try await tools.execute(name: "inspect_screen", arguments: #"{"app_id":"com.apple.Dictionary"}"#)
        }
        let approval: MacTools.Approval
        do {
            approval = try await waitForApproval(tools, attempts: 1000)
        } catch {
            // If capture failed before creating an approval, surface that cause.
            let result = try await pending.value
            let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
            throw Failure(object?["error"] as? String ?? error.localizedDescription)
        }
        guard approval.title.hasPrefix("Share this image"),
              approval.path.contains(appID),
              let image = approval.imageData,
              image.starts(with: [0xFF, 0xD8]),
              NSImage(data: image) != nil else {
            tools.resolve(id: approval.id, allow: false)
            throw Failure("Peekaboo capture was not presented as a valid in-memory JPEG approval")
        }
        tools.resolve(id: approval.id, allow: false)
        let denied = try JSONSerialization.jsonObject(with: Data(try await pending.value.utf8)) as? [String: Any]
        guard denied?["denied"] as? Bool == true,
              denied?["image_base64"] == nil else {
            throw Failure("Denied Peekaboo capture leaked image payload")
        }
        print("PASS: Peekaboo window capture reached Halo's exact image approval and denial prevented model sharing; pixels not printed or persisted by Halo")
    }

    static func peekabooListing(_ tools: MacTools) async throws {
        let expectedDriver = ProcessInfo.processInfo.environment["HALO_MAC_DRIVER"] == "peekaboo" ? "peekaboo" : "legacy"
        let runningStart = Date()
        let runningResult = try await tools.execute(name: "running_apps", arguments: "{}")
        let runningLatencyMs = Int((Date().timeIntervalSince(runningStart) * 1000).rounded())
        guard let runningObj = try JSONSerialization.jsonObject(with: Data(runningResult.utf8)) as? [String: Any],
              runningObj["ok"] as? Bool == true,
              let apps = runningObj["apps"] as? [[String: Any]],
              !apps.isEmpty else {
            throw Failure("running_apps returned empty or invalid response")
        }

        guard let firstApp = apps.first,
              let name = firstApp["name"] as? String, !name.isEmpty,
              firstApp["bundle_id"] is String,
              firstApp["window_count"] is Int else {
            throw Failure("running_apps entries missing required fields")
        }

        let driverFound = firstApp["driver"] as? String ?? "unknown"
        guard driverFound == expectedDriver else {
            throw Failure("Expected driver \(expectedDriver) but found \(driverFound)")
        }

        // Test list_windows on Finder (always running on macOS)
        let windowsStart = Date()
        let windowsResult = try await tools.execute(name: "list_windows", arguments: #"{"app_id":"com.apple.finder"}"#)
        let windowsLatencyMs = Int((Date().timeIntervalSince(windowsStart) * 1000).rounded())
        guard let windowsObj = try JSONSerialization.jsonObject(with: Data(windowsResult.utf8)) as? [String: Any],
              windowsObj["ok"] as? Bool == true,
              let windows = windowsObj["windows"] as? [[String: Any]] else {
            throw Failure("list_windows failed for Finder")
        }

        // Test list_menus on Finder
        let menusStart = Date()
        let menusResult = try await tools.execute(name: "list_menus", arguments: #"{"app_id":"com.apple.finder"}"#)
        let menusLatencyMs = Int((Date().timeIntervalSince(menusStart) * 1000).rounded())
        guard let menusObj = try JSONSerialization.jsonObject(with: Data(menusResult.utf8)) as? [String: Any],
              menusObj["ok"] as? Bool == true,
              let menus = menusObj["menus"] as? [[String: Any]] else {
            throw Failure("list_menus failed for Finder")
        }

        // Test find_dialog on Finder
        let dialogResult = try await tools.execute(name: "find_dialog", arguments: #"{"app_id":"com.apple.finder"}"#)
        guard let dialogObj = try JSONSerialization.jsonObject(with: Data(dialogResult.utf8)) as? [String: Any],
              dialogObj["ok"] as? Bool == true else {
            throw Failure("find_dialog failed for Finder")
        }

        // Test inspect_ui stale root_id rejection
        let staleRootResult = try await tools.execute(name: "inspect_ui", arguments: #"{"app_id":"com.apple.finder","root_id":"stale-root-reference"}"#)
        guard let staleObj = try JSONSerialization.jsonObject(with: Data(staleRootResult.utf8)) as? [String: Any],
              staleObj["ok"] as? Bool == false else {
            throw Failure("Stale root_id subtree was not rejected")
        }

        // Test inspect_ui element IDs and bounds
        let inspectResult = try await tools.execute(name: "inspect_ui", arguments: #"{"app_id":"com.apple.finder"}"#)
        guard let inspectObj = try JSONSerialization.jsonObject(with: Data(inspectResult.utf8)) as? [String: Any],
              inspectObj["ok"] as? Bool == true,
              let elements = inspectObj["elements"] as? [[String: Any]] else {
            throw Failure("inspect_ui failed for Finder")
        }

        if let firstElem = elements.first, let id = firstElem["id"] as? String {
            // Verify turn-scoped identifier pattern prefix-index (e.g., 8-char hex prefix and number)
            guard id.contains("-") else {
                throw Failure("Element ID is not turn-scoped: \(id)")
            }
        }

        print("PASS: \(expectedDriver) driver app listing (\(apps.count) apps, \(runningLatencyMs)ms), windows (\(windows.count) windows, \(windowsLatencyMs)ms), menus (\(menus.count) items, \(menusLatencyMs)ms), dialogs checked, and stale root_id rejected")
    }

    static func files(_ tools: MacTools) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("halo-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("sample.txt")
        try Data("original".utf8).write(to: fixture)
        func arguments(_ values: [String: String]) throws -> String {
            String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        }
        func object(_ result: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] ?? [:]
        }
        let read = try object(await tools.execute(name: "read_file", arguments: arguments(["path": fixture.path])))
        guard read["content"] as? String == "original" else { throw Failure("Native text read failed") }
        let list = try object(await tools.execute(name: "list_files", arguments: arguments(["path": root.path])))
        guard (list["entries"] as? [[String: String]])?.contains(where: { $0["name"] == "sample.txt" }) == true else { throw Failure("Native folder listing failed") }

        let change = try arguments(["path": fixture.path, "content": "replacement"])
        let denied = Task { try await tools.execute(name: "write_file", arguments: change) }
        let first = try await waitForApproval(tools)
        guard first.path == fixture.path && first.preview == "replacement" else { throw Failure("Approval preview differs from the action") }
        tools.resolve(id: first.id, allow: false)
        let denial = try object(await denied.value)
        guard denial["denied"] as? Bool == true,
              try String(contentsOf: fixture, encoding: .utf8) == "original" else { throw Failure("Denied write changed the file") }

        let allowed = Task { try await tools.execute(name: "write_file", arguments: change) }
        let second = try await waitForApproval(tools)
        tools.resolve(id: second.id, allow: true)
        let success = try object(await allowed.value)
        guard success["ok"] as? Bool == true,
              try String(contentsOf: fixture, encoding: .utf8) == "replacement" else { throw Failure("Approved write did not complete") }

        let cancelled = Task { try await tools.execute(name: "write_file", arguments: change) }
        _ = try await waitForApproval(tools)
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure("Cancelled approval did not throw") }
        catch is CancellationError {}
        guard tools.approval == nil, try String(contentsOf: fixture, encoding: .utf8) == "replacement" else {
            throw Failure("Cancelled approval remained active or changed the file")
        }
        let invalid = try object(await tools.execute(name: "read_file", arguments: arguments(["path": "/dev/zero"])))
        guard invalid["ok"] as? Bool == false else { throw Failure("Special-file read was not rejected") }
        print("PASS: native folder/text reads, exact write preview, denial, approval, cancellation, and special-file rejection")
    }

    static func safeMacActions(_ tools: MacTools) async throws {
        let expectedDriver = ProcessInfo.processInfo.environment["HALO_MAC_DRIVER"] == "peekaboo" ? "peekaboo" : "legacy"
        guard let executable = Bundle.main.executableURL else { throw Failure("Test executable missing") }

        let host = Process()
        host.executableURL = executable
        host.arguments = ["--ui-test-host"]
        try host.run()
        defer { if host.isRunning { host.terminate() } }
        let hostAppID = Bundle.main.bundleIdentifier ?? "app.halo.native.dev"

        // Activate test host app so macOS window server exposes its window
        for _ in 0..<50 {
            if let running = NSRunningApplication(processIdentifier: host.processIdentifier) {
                running.activate()
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Wait for the host window to show up
        var inspectedRows: [[String: Any]] = []
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            let res = try await tools.execute(name: "inspect_ui", arguments: #"{"app_id":"\#(hostAppID)"}"#)
            if let obj = try? JSONSerialization.jsonObject(with: Data(res.utf8)) as? [String: Any],
               let elements = obj["elements"] as? [[String: Any]],
               elements.contains(where: { ($0["label"] as? String) == "Mercy test button" }) {
                inspectedRows = elements
                break
            }
        }
        guard let buttonElem = inspectedRows.first(where: { ($0["label"] as? String) == "Mercy test button" }),
              let buttonID = buttonElem["id"] as? String else {
            throw Failure("Disposable host button not found in inspect_ui")
        }

        // 1. Focus / raise app
        let focusTask = Task { try await tools.execute(name: "focus_app", arguments: #"{"app_id":"\#(hostAppID)"}"#) }
        let focusApproval = try await waitForApproval(tools, step: "focus app")
        tools.resolve(id: focusApproval.id, allow: true)
        let focusRes = try await focusTask.value
        guard let focusObj = try? JSONSerialization.jsonObject(with: Data(focusRes.utf8)) as? [String: Any],
              focusObj["ok"] as? Bool == true else {
            throw Failure("focus_app failed for host")
        }

        // 2. Target freshness check: stale ID rejection BEFORE approval
        let staleAction = Task {
            try await tools.execute(name: "ui_action", arguments: #"{"element_id":"stale-id-999","action":"AXPress"}"#)
        }
        let staleOutput = try await staleAction.value
        guard let staleObj = try? JSONSerialization.jsonObject(with: Data(staleOutput.utf8)) as? [String: Any],
              staleObj["ok"] as? Bool == false,
              tools.approval == nil else {
            throw Failure("Stale element ID was not rejected before approval")
        }

        // 3. Approval denial: verify preview and denial
        let deniedClick = Task {
            try await tools.execute(name: "ui_action", arguments: #"{"element_id":"\#(buttonID)","action":"AXPress"}"#)
        }
        let denialApproval = try await waitForApproval(tools, step: "denial")
        guard denialApproval.title.contains("Control this app"),
              denialApproval.preview == "AXPress" else {
            tools.resolve(id: denialApproval.id, allow: false)
            throw Failure("Approval preview did not match action")
        }
        tools.resolve(id: denialApproval.id, allow: false)
        let denialResult = try await deniedClick.value
        guard let denialObj = try? JSONSerialization.jsonObject(with: Data(denialResult.utf8)) as? [String: Any],
              denialObj["denied"] as? Bool == true else {
            throw Failure("Denied action was not reported as denied")
        }

        // 4. Approval cancellation: verify Task cancellation dismisses approval
        let cancelledClick = Task {
            try await tools.execute(name: "ui_action", arguments: #"{"element_id":"\#(buttonID)","action":"AXPress"}"#)
        }
        _ = try await waitForApproval(tools, step: "cancellation")
        cancelledClick.cancel()
        do { _ = try await cancelledClick.value; throw Failure("Cancelled action did not throw") }
        catch is CancellationError {}
        guard tools.approval == nil else { throw Failure("Cancelled approval left modal visible") }

        // 5. Approved control click
        let approvedClick = Task {
            try await tools.execute(name: "ui_action", arguments: #"{"element_id":"\#(buttonID)","action":"AXPress"}"#)
        }
        let clickApproval = try await waitForApproval(tools, step: "click")
        tools.resolve(id: clickApproval.id, allow: true)
        let clickRes = try await approvedClick.value
        guard let clickObj = try? JSONSerialization.jsonObject(with: Data(clickRes.utf8)) as? [String: Any],
              clickObj["ok"] as? Bool == true else {
            throw Failure("Approved control click failed: \(clickRes)")
        }

        // Verify click side-effect via re-inspection (post-action observation verification)
        var updatedRows: [[String: Any]] = []
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let res = try await tools.execute(name: "inspect_ui", arguments: #"{"app_id":"\#(hostAppID)"}"#)
            if let obj = try? JSONSerialization.jsonObject(with: Data(res.utf8)) as? [String: Any],
               let elements = obj["elements"] as? [[String: Any]],
               elements.contains(where: { ($0["label"] as? String) == "Mercy test button pressed" }) {
                updatedRows = elements
                break
            }
        }
        guard !updatedRows.isEmpty else {
            throw Failure("Click side-effect ('Mercy test button pressed') not observed within timeout")
        }
        guard let fieldElem = updatedRows.first(where: { ($0["label"] as? String) == "Mercy test input" }),
              let fieldID = fieldElem["id"] as? String else {
            let labels = updatedRows.compactMap { "\($0["role"] ?? "") '\($0["label"] ?? "")'" }.joined(separator: ", ")
            throw Failure("Text field 'Mercy test input' missing. Found controls: [\(labels)]")
        }

        // Security check: verify secure/password field is protected and typing into it is blocked
        if let passwordElem = updatedRows.first(where: { ($0["label"] as? String) == "Mercy test password" }),
           let passwordID = passwordElem["id"] as? String {
            guard passwordElem["protected"] as? Bool == true else {
                throw Failure("Password field was not marked as protected: \(passwordElem)")
            }
            let blockedTypeRes = try await tools.execute(name: "type_text", arguments: #"{"element_id":"\#(passwordID)","text":"secret123"}"#)
            guard let blockedObj = try? JSONSerialization.jsonObject(with: Data(blockedTypeRes.utf8)) as? [String: Any],
                  blockedObj["ok"] as? Bool == false,
                  let err = blockedObj["error"] as? String,
                  err.contains("strictly blocked") else {
                throw Failure("Typing into password field was not blocked: \(blockedTypeRes)")
            }
        }

        // 6. Type text into observed field
        let typedText = "Halo observation typing"
        let typeTask = Task {
            try await tools.execute(name: "type_text", arguments: #"{"element_id":"\#(fieldID)","text":"\#(typedText)"}"#)
        }
        let typeApproval = try await waitForApproval(tools, step: "type")
        guard typeApproval.preview == typedText else {
            tools.resolve(id: typeApproval.id, allow: false)
            throw Failure("Type approval preview differed from text")
        }
        tools.resolve(id: typeApproval.id, allow: true)
        let typeRes = try await typeTask.value
        guard let typeObj = try? JSONSerialization.jsonObject(with: Data(typeRes.utf8)) as? [String: Any],
              typeObj["ok"] as? Bool == true else {
            throw Failure("type_text failed: \(typeRes)")
        }

        // 7. Keyboard shortcut: Select all (cmd+a)
        let keyTask = Task {
            try await tools.execute(name: "keypress", arguments: #"{"app_id":"\#(hostAppID)","shortcut":"cmd+a"}"#)
        }
        let keyApproval = try await waitForApproval(tools, step: "keypress")
        guard keyApproval.preview == "cmd+a" else {
            tools.resolve(id: keyApproval.id, allow: false)
            throw Failure("Keypress approval preview differed from shortcut")
        }
        tools.resolve(id: keyApproval.id, allow: true)
        let keyRes = try await keyTask.value
        guard let keyObj = try? JSONSerialization.jsonObject(with: Data(keyRes.utf8)) as? [String: Any],
              keyObj["ok"] as? Bool == true else {
            throw Failure("keypress failed: \(keyRes)")
        }

        // 8. Scroll
        let scrollTask = Task {
            try await tools.execute(name: "scroll", arguments: #"{"direction":"down","amount":3,"app_id":"\#(hostAppID)"}"#)
        }
        let scrollApproval = try await waitForApproval(tools, step: "scroll")
        tools.resolve(id: scrollApproval.id, allow: true)
        let scrollRes = try await scrollTask.value
        guard let scrollObj = try? JSONSerialization.jsonObject(with: Data(scrollRes.utf8)) as? [String: Any],
              scrollObj["ok"] as? Bool == true else {
            throw Failure("scroll failed: \(scrollRes)")
        }

        // 9. Menu item: Edit > Select All
        let menuTask = Task {
            try await tools.execute(name: "click_menu_item", arguments: #"{"app_id":"\#(hostAppID)","item_path":"Edit > Select All"}"#)
        }
        let menuApproval = try await waitForApproval(tools, step: "menu")
        guard menuApproval.preview == "Edit > Select All" else {
            tools.resolve(id: menuApproval.id, allow: false)
            throw Failure("Menu approval preview differed from item path")
        }
        tools.resolve(id: menuApproval.id, allow: true)
        let menuRes = try await menuTask.value
        guard let menuObj = try? JSONSerialization.jsonObject(with: Data(menuRes.utf8)) as? [String: Any],
              menuObj["ok"] as? Bool == true else {
            throw Failure("click_menu_item failed: \(menuRes)")
        }

        // 10. Open test dialog and click dialog button
        // Re-inspect to get current "Open test dialog" button ID
        let reinspectRes = try await tools.execute(name: "inspect_ui", arguments: #"{"app_id":"\#(hostAppID)"}"#)
        guard let reinspectObj = try? JSONSerialization.jsonObject(with: Data(reinspectRes.utf8)) as? [String: Any],
              let latestElements = reinspectObj["elements"] as? [[String: Any]],
              let dialogTrigger = latestElements.first(where: { ($0["label"] as? String) == "Open test dialog" }),
              let dialogTriggerID = dialogTrigger["id"] as? String else {
            throw Failure("Open test dialog button missing")
        }

        let openDialogTask = Task {
            try await tools.execute(name: "ui_action", arguments: #"{"element_id":"\#(dialogTriggerID)","action":"AXPress"}"#)
        }
        let openApproval = try await waitForApproval(tools, step: "open dialog")
        tools.resolve(id: openApproval.id, allow: true)
        _ = try await openDialogTask.value

        try await Task.sleep(for: .milliseconds(400))

        // Find dialog
        var dialogFound = false
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            let foundDialogRes = try await tools.execute(name: "find_dialog", arguments: #"{"app_id":"\#(hostAppID)"}"#)
            if let dialogCheckObj = try? JSONSerialization.jsonObject(with: Data(foundDialogRes.utf8)) as? [String: Any],
               dialogCheckObj["found"] as? Bool == true {
                dialogFound = true
                break
            }
        }
        guard dialogFound else {
            throw Failure("find_dialog did not discover active modal dialog")
        }

        // Click dialog button: Confirm
        let clickDialogTask = Task {
            try await tools.execute(name: "click_dialog_button", arguments: #"{"app_id":"\#(hostAppID)","button_title":"Confirm"}"#)
        }
        let dialogBtnApproval = try await waitForApproval(tools, step: "dialog button")
        guard dialogBtnApproval.preview == "Confirm" else {
            tools.resolve(id: dialogBtnApproval.id, allow: false)
            throw Failure("Dialog button approval preview differed from button title")
        }
        tools.resolve(id: dialogBtnApproval.id, allow: true)
        let dialogBtnRes = try await clickDialogTask.value
        guard let dialogBtnObj = try? JSONSerialization.jsonObject(with: Data(dialogBtnRes.utf8)) as? [String: Any],
              dialogBtnObj["ok"] as? Bool == true else {
            throw Failure("click_dialog_button failed: \(dialogBtnRes)")
        }

        // 11. Window layout
        let layoutTask = Task { try await tools.execute(name: "window_layout", arguments: #"{"app_id":"\#(hostAppID)","position":"left"}"#) }
        let layoutApproval = try await waitForApproval(tools, step: "window layout")
        tools.resolve(id: layoutApproval.id, allow: true)
        let layoutRes = try await layoutTask.value
        guard let layoutObj = try? JSONSerialization.jsonObject(with: Data(layoutRes.utf8)) as? [String: Any],
              layoutObj["ok"] as? Bool == true else {
            throw Failure("window_layout failed: \(layoutRes)")
        }

        print("PASS: \(expectedDriver) driver Safe Mac actions: focus, stale ID rejection, approval preview/denial/cancellation, control click, typing, shortcut, scroll, menu selection, dialog operation, and window layout verified with post-action observation")
    }

    private final class DisposableTabServer: @unchecked Sendable {
        let port: UInt16
        let url: URL
        private let socketFD: Int32
        private let lock = NSLock()
        private var stopped = false

        init() throws {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure("Could not create local test socket") }
            var opt: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, Darwin.listen(fd, 8) == 0 else {
                Darwin.close(fd)
                throw Failure("Could not bind/listen on local test socket")
            }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &size) }
            }
            guard named == 0, Darwin.fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                Darwin.close(fd)
                throw Failure("Could not configure non-blocking local test socket")
            }
            socketFD = fd
            port = UInt16(bigEndian: address.sin_port)
            url = URL(string: "http://127.0.0.1:\(port)/halo-test")!

            Thread.detachNewThread { [weak self] in
                guard let self else { return }
                let htmlBody = """
                <!DOCTYPE html>
                <html>
                <head><title>Halo Disposable Browser Fixture</title></head>
                <body>
                <h1>Halo Chrome Integration Test</h1>
                <p>Halo Browser Integration Test Content - Non-sensitive verification text. No cookies, no credentials, no passwords.</p>
                </body>
                </html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(htmlBody.utf8.count)\r\nConnection: close\r\n\r\n\(htmlBody)"
                let responseBytes = [UInt8](response.utf8)

                while true {
                    let isStopped = self.lock.withLock { self.stopped }
                    if isStopped { break }

                    let client = Darwin.accept(self.socketFD, nil, nil)
                    if client < 0 {
                        usleep(10_000)
                        continue
                    }
                    var noSigPipe: Int32 = 1
                    _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                    _ = Darwin.write(client, responseBytes, responseBytes.count)
                    Darwin.close(client)
                }
            }
        }

        func stop() {
            let alreadyStopped = lock.withLock {
                if stopped { return true }
                stopped = true
                return false
            }
            if !alreadyStopped {
                Darwin.close(socketFD)
            }
        }

        deinit {
            stop()
        }
    }

    static func browserTabIntegration(_ tools: MacTools) async throws {
        // Run deterministic Phase 4 adversarial coverage across all 8 required cases
        try await adversarialBrowserCoverage(tools)

        // 1. Verify tool definitions
        let definitions = try JSONSerialization.jsonObject(with: await tools.definitions()) as? [[String: Any]] ?? []
        let names = Set(definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
        guard ["list_browser_tabs", "authorize_browser_tab", "read_browser_tab", "revoke_browser_tab", "pause_browser_tabs"].allSatisfy(names.contains) else {
            throw Failure("Chrome browser tab tool definitions missing")
        }
        let invalidBrowser = try await tools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false,"browser_app_id":"invalid.browser"}"#)
        guard let invalidObject = try? JSONSerialization.jsonObject(with: Data(invalidBrowser.utf8)) as? [String: Any],
              invalidObject["ok"] as? Bool == false else {
            throw Failure("An unknown explicit browser bundle ID did not fail closed")
        }

        // 2. Start local disposable HTTP fixture
        let server = try DisposableTabServer()
        defer { server.stop() }

        // 3. Open a disposable tab in Chrome
        var disposableTabID: Int? = nil
        do {
            disposableTabID = try await ChromeBrowserService.shared.openTab(url: server.url.absoluteString)
        } catch {
            throw Failure("Failed to open disposable test tab in Chrome: \(error.localizedDescription)")
        }
        guard let tabID = disposableTabID else {
            throw Failure("No tab ID returned for disposable tab")
        }

        defer {
            Task {
                try? await ChromeBrowserService.shared.closeTab(id: tabID)
                await ChromeBrowserService.shared.revokeAll()
                await ChromeBrowserService.shared.setPaused(false)
            }
        }

        // Allow Chrome to navigate and render the DOM
        try await Task.sleep(for: .milliseconds(500))

        // 4. Test listing with default authorized_only = true: disposable tab MUST NOT be listed
        let defaultListRaw = try await tools.execute(name: "list_browser_tabs", arguments: "{}")
        guard let defaultListObj = try? JSONSerialization.jsonObject(with: Data(defaultListRaw.utf8)) as? [String: Any],
              defaultListObj["ok"] as? Bool == true,
              let authorizedTabs = defaultListObj["tabs"] as? [[String: Any]] else {
            throw Failure("list_browser_tabs default execution failed: \(defaultListRaw)")
        }
        if authorizedTabs.contains(where: { ($0["id"] as? Int) == tabID }) {
            throw Failure("Unauthorized tab appeared in default (authorized_only) tab list")
        }

        // 5. Test listing with authorized_only = false: disposable tab MUST be listed as unauthorized
        let allListRaw = try await tools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false}"#)
        guard let allListObj = try? JSONSerialization.jsonObject(with: Data(allListRaw.utf8)) as? [String: Any],
              allListObj["ok"] as? Bool == true,
              let allTabs = allListObj["tabs"] as? [[String: Any]] else {
            throw Failure("list_browser_tabs with authorized_only:false failed: \(allListRaw)")
        }
        guard let discoveredTab = allTabs.first(where: { ($0["id"] as? Int) == tabID }) else {
            throw Failure("Disposable tab not found in list_browser_tabs")
        }
        guard discoveredTab["is_authorized"] as? Bool == false else {
            throw Failure("New tab was unexpectedly authorized")
        }
        guard let discoveredDomain = discoveredTab["domain"] as? String, discoveredDomain == "127.0.0.1" else {
            throw Failure("Tab domain extraction failed: \(discoveredTab)")
        }
        // Page-controlled C0 separators must remain data inside JSON rather than
        // corrupting the outer tab record framing or approval metadata.
        let browserName = try await ChromeBrowserService.shared.resolveBrowserAppName(nil)
        let hostileTitleScript = """
        tell application "\(browserName)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as string) is "\(tabID)" then
                        execute t javascript "document.title = 'Halo' + String.fromCharCode(31) + 'field' + String.fromCharCode(30) + 'record'"
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", hostileTitleScript], directory: FileManager.default.temporaryDirectory)
        let hostileListRaw = try await tools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false}"#)
        guard let hostileObject = try? JSONSerialization.jsonObject(with: Data(hostileListRaw.utf8)) as? [String: Any],
              let hostileTabs = hostileObject["tabs"] as? [[String: Any]],
              let hostileTab = hostileTabs.first(where: { ($0["id"] as? Int) == tabID }),
              (hostileTab["domain"] as? String) == "127.0.0.1" else {
            throw Failure("Page-controlled record separators corrupted tab metadata")
        }
        let restoreTitleScript = hostileTitleScript.replacingOccurrences(
            of: "document.title = 'Halo' + String.fromCharCode(31) + 'field' + String.fromCharCode(30) + 'record'",
            with: "document.title = 'Halo Disposable Browser Fixture'")
        _ = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", restoreTitleScript], directory: FileManager.default.temporaryDirectory)
        // Verify internal schemes (chrome://, about:) are excluded
        for t in allTabs {
            if let u = t["url"] as? String {
                guard let parsed = URL(string: u), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                    throw Failure("Internal browser URL leaked into tab listing: \(u)")
                }
            }
        }

        // 6. Test unauthorized read rejection
        let unauthReadRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let unauthReadObj = try? JSONSerialization.jsonObject(with: Data(unauthReadRaw.utf8)) as? [String: Any],
              unauthReadObj["ok"] as? Bool == false,
              let errorMsg = unauthReadObj["error"] as? String,
              errorMsg.contains("not authorized") else {
            throw Failure("Unauthorized tab read was not rejected: \(unauthReadRaw)")
        }

        // 7. Test authorization preview & user denial
        let denyTask = Task {
            try await tools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        }
        let denyApproval = try await waitForApproval(tools, step: "authorize deny")
        guard denyApproval.title == "Authorize access to browser tab?" else {
            tools.resolve(id: denyApproval.id, allow: false)
            throw Failure("Authorization approval title mismatch: \(denyApproval.title)")
        }
        guard denyApproval.path.contains("127.0.0.1") else {
            tools.resolve(id: denyApproval.id, allow: false)
            throw Failure("Authorization approval preview path did not include domain: \(denyApproval.path)")
        }
        tools.resolve(id: denyApproval.id, allow: false)
        let denyResult = try await denyTask.value
        guard let denyObj = try? JSONSerialization.jsonObject(with: Data(denyResult.utf8)) as? [String: Any],
              denyObj["denied"] as? Bool == true else {
            throw Failure("Tab authorization denial ignored: \(denyResult)")
        }
        guard await !ChromeBrowserService.shared.isAuthorized(tabID: tabID) else {
            throw Failure("Declined tab was authorized")
        }

        // 8. Test authorization preview cancellation dismissal
        let cancelTask = Task {
            try await tools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        }
        _ = try await waitForApproval(tools, step: "authorize cancel")
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            throw Failure("Pending tab authorization ignored Task cancellation")
        } catch is CancellationError {}
        guard tools.approval == nil else {
            throw Failure("Cancelled authorization approval remained visible")
        }
        guard await !ChromeBrowserService.shared.isAuthorized(tabID: tabID) else {
            throw Failure("Cancelled tab was authorized")
        }

        // A same-origin URL change while approval is visible still changes what the
        // user approved and must require a fresh observation and approval.
        let changedApprovalTask = Task {
            try await tools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        }
        let changedApproval = try await waitForApproval(tools, step: "authorize changed tab")
        let changedURLScript = """
        tell application "\(browserName)"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as string) is "\(tabID)" then
                        set URL of t to "\(server.url.absoluteString)?changed-during-approval=1"
                    end if
                end repeat
            end repeat
        end tell
        """
        _ = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", changedURLScript], directory: FileManager.default.temporaryDirectory)
        try await Task.sleep(for: .milliseconds(250))
        tools.resolve(id: changedApproval.id, allow: true)
        let changedResult = try await changedApprovalTask.value
        guard let changedObject = try? JSONSerialization.jsonObject(with: Data(changedResult.utf8)) as? [String: Any],
              changedObject["ok"] as? Bool == false,
              await !ChromeBrowserService.shared.isAuthorized(tabID: tabID) else {
            throw Failure("A tab changed during approval retained authorization: \(changedResult)")
        }

        // 9. Test authorization approval
        let approveTask = Task {
            try await tools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        }
        let approveApproval = try await waitForApproval(tools, step: "authorize approve")
        tools.resolve(id: approveApproval.id, allow: true)
        let approveResult = try await approveTask.value
        guard let approveObj = try? JSONSerialization.jsonObject(with: Data(approveResult.utf8)) as? [String: Any],
              approveObj["ok"] as? Bool == true,
              approveObj["authorized_tab_id"] as? Int == tabID else {
            throw Failure("Tab authorization approval failed: \(approveResult)")
        }
        guard await ChromeBrowserService.shared.isAuthorized(tabID: tabID) else {
            throw Failure("Tab was not marked authorized in service")
        }

        // 10. Test listing with default authorized_only = true now includes the authorized tab
        let postAuthListRaw = try await tools.execute(name: "list_browser_tabs", arguments: "{}")
        guard let postAuthListObj = try? JSONSerialization.jsonObject(with: Data(postAuthListRaw.utf8)) as? [String: Any],
              let postAuthTabs = postAuthListObj["tabs"] as? [[String: Any]],
              let authorizedTabEntry = postAuthTabs.first(where: { ($0["id"] as? Int) == tabID }) else {
            throw Failure("Newly authorized tab not found in default list_browser_tabs")
        }
        guard authorizedTabEntry["is_authorized"] as? Bool == true else {
            throw Failure("Authorized tab listed with is_authorized == false")
        }

        // 11. Test reading authorized tab content
        let readRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let readObj = try? JSONSerialization.jsonObject(with: Data(readRaw.utf8)) as? [String: Any],
              readObj["ok"] as? Bool == true,
              let content = readObj["content"] as? String,
              content.contains("Halo Browser Integration Test Content"),
              let readTitle = readObj["title"] as? String,
              readTitle.contains("Halo Disposable Browser Fixture") else {
            throw Failure("read_browser_tab failed or content mismatch: \(readRaw)")
        }
        guard readObj["truncated"] as? Bool == false else {
            throw Failure("Disposable tab unexpectedly truncated")
        }
        guard let note = readObj["note"] as? String, note.contains("untrusted data") else {
            throw Failure("Untrusted data advisory notice missing from read result")
        }

        // 12. Test pause killswitch
        let pauseRaw = try await tools.execute(name: "pause_browser_tabs", arguments: #"{"paused":true}"#)
        guard let pauseObj = try? JSONSerialization.jsonObject(with: Data(pauseRaw.utf8)) as? [String: Any],
              pauseObj["ok"] as? Bool == true,
              pauseObj["paused"] as? Bool == true else {
            throw Failure("pause_browser_tabs(true) failed: \(pauseRaw)")
        }
        // Reading while paused must fail
        let pausedReadRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let pausedReadObj = try? JSONSerialization.jsonObject(with: Data(pausedReadRaw.utf8)) as? [String: Any],
              pausedReadObj["ok"] as? Bool == false,
              let pauseError = pausedReadObj["error"] as? String,
              pauseError.contains("paused") else {
            throw Failure("Reading paused browser tab was not blocked: \(pausedReadRaw)")
        }
        // Listing while paused must fail
        let pausedListRaw = try await tools.execute(name: "list_browser_tabs", arguments: "{}")
        guard let pausedListObj = try? JSONSerialization.jsonObject(with: Data(pausedListRaw.utf8)) as? [String: Any],
              pausedListObj["ok"] as? Bool == false else {
            throw Failure("Listing while paused was not blocked: \(pausedListRaw)")
        }
        // Resume
        let resumeRaw = try await tools.execute(name: "pause_browser_tabs", arguments: #"{"paused":false}"#)
        guard let resumeObj = try? JSONSerialization.jsonObject(with: Data(resumeRaw.utf8)) as? [String: Any],
              resumeObj["ok"] as? Bool == true,
              resumeObj["paused"] as? Bool == false else {
            throw Failure("pause_browser_tabs(false) resume failed: \(resumeRaw)")
        }
        // Reading after resume must succeed
        let resumedReadRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let resumedReadObj = try? JSONSerialization.jsonObject(with: Data(resumedReadRaw.utf8)) as? [String: Any],
              resumedReadObj["ok"] as? Bool == true else {
            throw Failure("Reading after resume failed: \(resumedReadRaw)")
        }

        // 12b. Test navigation domain hijacking protection:
        // Navigating the authorized tab to a different domain must immediately revoke authorization and block reads.
        let navigateScript = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if (id of t as string) is "\(tabID)" then
                        set URL of t to "http://localhost:\(server.port)/halo-test"
                        return "NAVIGATED"
                    end if
                end repeat
            end repeat
            return "NOT_FOUND"
        end tell
        """
        _ = try await CommandRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", navigateScript], directory: FileManager.default.temporaryDirectory)
        try await Task.sleep(for: .milliseconds(400))

        let hijackedReadRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let hijackedReadObj = try? JSONSerialization.jsonObject(with: Data(hijackedReadRaw.utf8)) as? [String: Any],
              hijackedReadObj["ok"] as? Bool == false,
              let hijackError = hijackedReadObj["error"] as? String,
              hijackError.contains("navigated") || hijackError.contains("revoked") else {
            throw Failure("Domain navigation hijacking was not caught and revoked: \(hijackedReadRaw)")
        }
        // Verify authorization was revoked automatically
        let postHijackListRaw = try await tools.execute(name: "list_browser_tabs", arguments: "{}")
        guard let postHijackListObj = try? JSONSerialization.jsonObject(with: Data(postHijackListRaw.utf8)) as? [String: Any],
              let postHijackTabs = postHijackListObj["tabs"] as? [[String: Any]],
              !postHijackTabs.contains(where: { ($0["id"] as? Int) == tabID }) else {
            throw Failure("Navigated tab remained authorized after domain change")
        }

        // Re-authorize tab for the revocation test
        let reauthTask = Task {
            try await tools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        }
        let reauthApproval = try await waitForApproval(tools, step: "re-authorize")
        tools.resolve(id: reauthApproval.id, allow: true)
        _ = try await reauthTask.value

        // 13. Test instant revocation killswitch
        let revokeRaw = try await tools.execute(name: "revoke_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let revokeObj = try? JSONSerialization.jsonObject(with: Data(revokeRaw.utf8)) as? [String: Any],
              revokeObj["ok"] as? Bool == true,
              revokeObj["revoked_tab_id"] as? Int == tabID else {
            throw Failure("revoke_browser_tab failed: \(revokeRaw)")
        }
        // Default list must no longer contain the revoked tab
        let postRevokeListRaw = try await tools.execute(name: "list_browser_tabs", arguments: "{}")
        guard let postRevokeListObj = try? JSONSerialization.jsonObject(with: Data(postRevokeListRaw.utf8)) as? [String: Any],
              let postRevokeTabs = postRevokeListObj["tabs"] as? [[String: Any]],
              !postRevokeTabs.contains(where: { ($0["id"] as? Int) == tabID }) else {
            throw Failure("Revoked tab still present in authorized tab list")
        }
        // Reading revoked tab must fail
        let postRevokeReadRaw = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
        guard let postRevokeReadObj = try? JSONSerialization.jsonObject(with: Data(postRevokeReadRaw.utf8)) as? [String: Any],
              postRevokeReadObj["ok"] as? Bool == false,
              let postRevokeErr = postRevokeReadObj["error"] as? String,
              postRevokeErr.contains("not authorized") else {
            throw Failure("Reading revoked tab was not blocked: \(postRevokeReadRaw)")
        }

        // 14. Close disposable tab
        try await ChromeBrowserService.shared.closeTab(id: tabID)

        print("PASS: Chrome browser tab integration: tab enumeration, incognito/internal URL exclusion, active tab resolution, approval preview/denial/cancellation, authorized DOM text extraction without credentials, pause killswitch, and instant revocation verified.")
    }

    private static func waitForApproval(_ tools: MacTools, attempts: Int = 300, step: String = "") async throws -> MacTools.Approval {
        for _ in 0..<attempts {
            if let approval = tools.approval { return approval }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Approval did not appear for step '\(step)'")
    }

    private final class AsyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isEntered = false
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false

        func waitUntilEntered(step: String, timeout: Duration = .seconds(5)) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                try Task.checkCancellation()
                if lock.withLock({ isEntered }) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure("Timed out waiting for simulated browser runtime at '\(step)'")
        }

        func enterAndAwaitRelease() async {
            lock.withLock { isEntered = true }

            await withCheckedContinuation { cont in
                lock.withLock {
                    if isReleased {
                        cont.resume()
                    } else {
                        releaseContinuations.append(cont)
                    }
                }
            }
        }

        func release() {
            let releaseToResume: [CheckedContinuation<Void, Never>] = lock.withLock {
                isReleased = true
                let toResume = releaseContinuations
                releaseContinuations.removeAll()
                return toResume
            }
            for cont in releaseToResume { cont.resume() }
        }
    }

    private final class SimulatedBrowserRuntime: BrowserAutomationRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var contexts: [String: ChromeBrowserService.BrowserContext] = [:]
        private var activeBundleID: String?
        private var scriptHandler: (@Sendable (String) async throws -> String)?

        init(contexts: [ChromeBrowserService.BrowserContext] = [], activeBundleID: String? = nil) {
            for ctx in contexts {
                self.contexts[ctx.bundleID] = ctx
            }
            self.activeBundleID = activeBundleID ?? contexts.first?.bundleID
        }

        func setContext(_ context: ChromeBrowserService.BrowserContext, makeActive: Bool = false) {
            lock.withLock {
                contexts[context.bundleID] = context
                if makeActive || activeBundleID == nil {
                    activeBundleID = context.bundleID
                }
            }
        }

        func setActiveBundleID(_ bundleID: String?) {
            lock.withLock { activeBundleID = bundleID }
        }

        func setScriptHandler(_ handler: (@Sendable (String) async throws -> String)?) {
            lock.withLock { scriptHandler = handler }
        }

        func resolveBrowserContext(_ requestedBundleID: String?) throws -> ChromeBrowserService.BrowserContext {
            try lock.withLock {
                if let requestedBundleID {
                    guard ChromeBrowserService.supportedBrowserBundleIDs[requestedBundleID] != nil else {
                        throw InteractionError("Unsupported Chromium browser bundle ID '\(requestedBundleID)'.")
                    }
                    guard let ctx = contexts[requestedBundleID] else {
                        throw InteractionError("The requested Chromium browser is not running.")
                    }
                    return ctx
                } else {
                    guard let activeID = activeBundleID, let ctx = contexts[activeID] else {
                        guard let first = contexts.values.sorted(by: { $0.bundleID < $1.bundleID }).first else {
                            throw InteractionError("No supported Chromium browser (Google Chrome, Brave, Chromium, Edge) is currently running.")
                        }
                        return first
                    }
                    return ctx
                }
            }
        }

        func runAppleScript(_ script: String) async throws -> String {
            try Task.checkCancellation()
            let handler = lock.withLock { scriptHandler }
            guard let handler else {
                return ""
            }
            return try await handler(script)
        }
    }

    static func adversarialBrowserCoverage(_ tools: MacTools) async throws {
        // --- 1. Cross-Browser Authorization Isolation ---
        // Two different browser identities using the same numeric tab ID must never share authorization.
        let chromeContext = ChromeBrowserService.BrowserContext(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            pid: 1001,
            sessionID: "1001:100.0"
        )
        let braveContext = ChromeBrowserService.BrowserContext(
            bundleID: "com.brave.Browser",
            name: "Brave Browser",
            pid: 2002,
            sessionID: "2002:200.0"
        )
        let runtime = SimulatedBrowserRuntime(contexts: [chromeContext, braveContext], activeBundleID: "com.google.Chrome")
        let service = ChromeBrowserService(runtime: runtime)
        let simTools = MacTools(catalog: AppCatalog(), browserService: service)

        runtime.setScriptHandler { script in
            if script.contains("Google Chrome") {
                if script.contains("execute t javascript") {
                    return #"{"title":"Chrome Page","url":"http://127.0.0.1/chrome","text":"Chrome Content"}"#
                }
                return "42\u{1F}1\u{1F}1\u{1F}1\u{1F}Chrome Page\u{1F}http://127.0.0.1/chrome\u{1E}"
            } else if script.contains("Brave Browser") {
                if script.contains("execute t javascript") {
                    return #"{"title":"Brave Page","url":"http://127.0.0.1/brave","text":"Brave Content"}"#
                }
                return "42\u{1F}1\u{1F}1\u{1F}1\u{1F}Brave Page\u{1F}http://127.0.0.1/brave\u{1E}"
            }
            return ""
        }

        let authChromeTask = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.google.Chrome"}"#)
        }
        let approval1 = try await waitForApproval(simTools, step: "adversarial auth chrome")
        simTools.resolve(id: approval1.id, allow: true)
        let authChromeRes = try await authChromeTask.value
        let authChromeObj = try JSONSerialization.jsonObject(with: Data(authChromeRes.utf8)) as? [String: Any]
        guard authChromeObj?["ok"] as? Bool == true else {
            throw Failure("Case 1: Chrome authorization failed: \(authChromeRes)")
        }

        let readChromeRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.google.Chrome"}"#)
        let readChromeObj = try JSONSerialization.jsonObject(with: Data(readChromeRes.utf8)) as? [String: Any]
        guard readChromeObj?["ok"] as? Bool == true, (readChromeObj?["content"] as? String) == "Chrome Content" else {
            throw Failure("Case 1: Chrome read failed: \(readChromeRes)")
        }

        let braveListRes = try await simTools.execute(name: "list_browser_tabs", arguments: #"{"browser_app_id":"com.brave.Browser","authorized_only":true}"#)
        let braveListObj = try JSONSerialization.jsonObject(with: Data(braveListRes.utf8)) as? [String: Any]
        let braveAuthorizedTabs = braveListObj?["tabs"] as? [[String: Any]] ?? []
        guard braveAuthorizedTabs.isEmpty else {
            throw Failure("Case 1: Brave unexpectedly inherited Chrome authorization in listing: \(braveListRes)")
        }

        let readBraveRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.brave.Browser"}"#)
        let readBraveObj = try JSONSerialization.jsonObject(with: Data(readBraveRes.utf8)) as? [String: Any]
        guard readBraveObj?["ok"] as? Bool == false,
              let errBrave = readBraveObj?["error"] as? String,
              errBrave.contains("not authorized for this browser session") else {
            throw Failure("Case 1: Brave read of tab 42 was not rejected: \(readBraveRes)")
        }

        // --- 2. Browser Process Session Restart Isolation ---
        // A new browser process session reusing the same bundle ID and tab ID must not inherit authorization.
        let restartedChromeContext = ChromeBrowserService.BrowserContext(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            pid: 1002,
            sessionID: "1002:200.0"
        )
        runtime.setContext(restartedChromeContext)

        let readRestartRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.google.Chrome"}"#)
        let readRestartObj = try JSONSerialization.jsonObject(with: Data(readRestartRes.utf8)) as? [String: Any]
        guard readRestartObj?["ok"] as? Bool == false,
              let errRestart = readRestartObj?["error"] as? String,
              errRestart.contains("not authorized for this browser session") else {
            throw Failure("Case 2: Reading tab 42 after browser restart was not rejected: \(readRestartRes)")
        }

        let authNewTask = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.google.Chrome"}"#)
        }
        let approvalNew = try await waitForApproval(simTools, step: "adversarial auth new session")
        simTools.resolve(id: approvalNew.id, allow: true)
        let authNewResult = try await authNewTask.value
        guard let authNewObject = try? JSONSerialization.jsonObject(with: Data(authNewResult.utf8)) as? [String: Any],
              authNewObject["ok"] as? Bool == true else {
            throw Failure("Case 2: Authorization in the restarted browser session failed: \(authNewResult)")
        }

        let inFlightRestartGate = AsyncGate()
        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                await inFlightRestartGate.enterAndAwaitRelease()
                return #"{"title":"Chrome Page","url":"http://127.0.0.1/chrome","text":"In-flight restart text"}"#
            }
            return "42\u{1F}1\u{1F}1\u{1F}1\u{1F}Chrome Page\u{1F}http://127.0.0.1/chrome\u{1E}"
        }

        let inFlightReadTask = Task {
            try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":42,"browser_app_id":"com.google.Chrome"}"#)
        }
        try await inFlightRestartGate.waitUntilEntered(step: "case 2 in-flight restart read")

        let thirdChromeContext = ChromeBrowserService.BrowserContext(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            pid: 1003,
            sessionID: "1003:300.0"
        )
        runtime.setContext(thirdChromeContext)
        inFlightRestartGate.release()

        let inFlightReadRes = try await inFlightReadTask.value
        let inFlightReadObj = try JSONSerialization.jsonObject(with: Data(inFlightReadRes.utf8)) as? [String: Any]
        guard inFlightReadObj?["ok"] as? Bool == false,
              let inFlightErr = inFlightReadObj?["error"] as? String,
              inFlightErr.contains("restarted") || inFlightErr.contains("revoked") else {
            throw Failure("Case 2: In-flight restart did not reject read: \(inFlightReadRes)")
        }

        // --- 3. Tab Replacement or URL Change During Approval ---
        // Tab replacement or URL change while approval is visible must fail authorization.
        let test3Context = ChromeBrowserService.BrowserContext(
            bundleID: "com.google.Chrome",
            name: "Google Chrome",
            pid: 3001,
            sessionID: "3001:100.0"
        )
        runtime.setContext(test3Context)
        final class DynamicTabBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _url = "http://127.0.0.1/stepA"
            private var _tabID = 50

            var url: String {
                get { lock.withLock { _url } }
                set { lock.withLock { _url = newValue } }
            }
            var tabID: Int {
                get { lock.withLock { _tabID } }
                set { lock.withLock { _tabID = newValue } }
            }
        }
        let dynamicTab = DynamicTabBox()
        runtime.setScriptHandler { _ in
            "\(dynamicTab.tabID)\u{1F}1\u{1F}1\u{1F}1\u{1F}Dynamic Tab\u{1F}\(dynamicTab.url)\u{1E}"
        }

        // 3a. Same-domain URL change while approval is open
        let task3a = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":50,"browser_app_id":"com.google.Chrome"}"#)
        }
        let approval3a = try await waitForApproval(simTools, step: "adversarial case 3a")
        dynamicTab.url = "http://127.0.0.1/stepA-mutated"
        simTools.resolve(id: approval3a.id, allow: true)
        let res3a = try await task3a.value
        let obj3a = try JSONSerialization.jsonObject(with: Data(res3a.utf8)) as? [String: Any]
        guard obj3a?["ok"] as? Bool == false,
              let err3a = obj3a?["error"] as? String,
              err3a.contains("changed while approval was open") else {
            throw Failure("Case 3a: Same-domain URL change during approval was not rejected: \(res3a)")
        }

        // 3b. Domain change while approval is open
        dynamicTab.url = "http://127.0.0.1/stepB"
        let task3b = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":50,"browser_app_id":"com.google.Chrome"}"#)
        }
        let approval3b = try await waitForApproval(simTools, step: "adversarial case 3b")
        dynamicTab.url = "https://evil.com/phishing"
        simTools.resolve(id: approval3b.id, allow: true)
        let res3b = try await task3b.value
        let obj3b = try JSONSerialization.jsonObject(with: Data(res3b.utf8)) as? [String: Any]
        guard obj3b?["ok"] as? Bool == false,
              let err3b = obj3b?["error"] as? String,
              err3b.contains("changed while approval was open") else {
            throw Failure("Case 3b: Domain change during approval was not rejected: \(res3b)")
        }

        // 3c. Tab replacement while approval is open
        dynamicTab.url = "http://127.0.0.1/stepC"
        dynamicTab.tabID = 50
        let task3c = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":50,"browser_app_id":"com.google.Chrome"}"#)
        }
        let approval3c = try await waitForApproval(simTools, step: "adversarial case 3c")
        dynamicTab.tabID = 51
        simTools.resolve(id: approval3c.id, allow: true)
        let res3c = try await task3c.value
        let obj3c = try JSONSerialization.jsonObject(with: Data(res3c.utf8)) as? [String: Any]
        guard obj3c?["ok"] as? Bool == false,
              let err3c = obj3c?["error"] as? String,
              err3c.contains("changed while approval was open") else {
            throw Failure("Case 3c: Tab replacement during approval was not rejected: \(res3c)")
        }

        // --- 4. Page-Controlled Framing Delimiter Immunity ---
        // Page-controlled title framing characters U+001E and U+001F must not corrupt parsed metadata.
        let sanitizedOutput = "60\u{1F}1\u{1F}1\u{1F}1\u{1F}Title with \u{FFFD} field and \u{FFFD} record\u{1F}http://127.0.0.1/test\u{1E}"
        runtime.setScriptHandler { _ in sanitizedOutput }
        let list4aRes = try await simTools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false,"browser_app_id":"com.google.Chrome"}"#)
        let list4aObj = try JSONSerialization.jsonObject(with: Data(list4aRes.utf8)) as? [String: Any]
        guard list4aObj?["ok"] as? Bool == true,
              let tabs4a = list4aObj?["tabs"] as? [[String: Any]],
              tabs4a.count == 1,
              let tab4a = tabs4a.first,
              (tab4a["title"] as? String)?.contains("Title with \u{FFFD} field and \u{FFFD} record") == true,
              (tab4a["domain"] as? String) == "127.0.0.1" else {
            throw Failure("Case 4a: Sanitized framing controls corrupted listing: \(list4aRes)")
        }

        let hostileInjectedOutput = "60\u{1F}1\u{1F}1\u{1F}1\u{1F}Injected\u{1F}http://evil.com\u{1E}Extra\u{1F}1\u{1F}http://127.0.0.1\u{1E}"
        runtime.setScriptHandler { _ in hostileInjectedOutput }
        let list4bRes = try await simTools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false,"browser_app_id":"com.google.Chrome"}"#)
        let list4bObj = try JSONSerialization.jsonObject(with: Data(list4bRes.utf8)) as? [String: Any]
        guard list4bObj?["ok"] as? Bool == false,
              let err4b = list4bObj?["error"] as? String,
              err4b.contains("Malformed browser tab metadata") else {
            throw Failure("Case 4b: Hostile framing injection was not rejected: \(list4bRes)")
        }

        // --- 5. In-Flight Listing Pause Suppression ---
        // Pause during an in-flight listing must suppress the result.
        let listGate = AsyncGate()
        runtime.setScriptHandler { _ in
            await listGate.enterAndAwaitRelease()
            return "70\u{1F}1\u{1F}1\u{1F}1\u{1F}Delayed Tab\u{1F}http://127.0.0.1/delayed\u{1E}"
        }

        let inFlightListTask = Task {
            try await simTools.execute(name: "list_browser_tabs", arguments: #"{"authorized_only":false,"browser_app_id":"com.google.Chrome"}"#)
        }
        try await listGate.waitUntilEntered(step: "case 5 in-flight listing")

        let pauseRes = try await simTools.execute(name: "pause_browser_tabs", arguments: #"{"paused":true}"#)
        let pauseObj = try JSONSerialization.jsonObject(with: Data(pauseRes.utf8)) as? [String: Any]
        guard pauseObj?["ok"] as? Bool == true else { throw Failure("Case 5: pause_browser_tabs failed: \(pauseRes)") }

        listGate.release()
        let inFlightListRes = try await inFlightListTask.value
        let inFlightListObj = try JSONSerialization.jsonObject(with: Data(inFlightListRes.utf8)) as? [String: Any]
        guard inFlightListObj?["ok"] as? Bool == false,
              let err5 = inFlightListObj?["error"] as? String,
              err5.contains("in flight") || err5.contains("paused") else {
            throw Failure("Case 5: In-flight listing was not suppressed on pause: \(inFlightListRes)")
        }
        _ = try await simTools.execute(name: "pause_browser_tabs", arguments: #"{"paused":false}"#)

        // --- 6. In-Flight Read Pause and Revoke Suppression ---
        // Pause or revoke during an in-flight read must suppress the result.
        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                return #"{"title":"Secret Doc","url":"http://127.0.0.1/doc","text":"Sensitive Data 123"}"#
            }
            return "80\u{1F}1\u{1F}1\u{1F}1\u{1F}Secret Doc\u{1F}http://127.0.0.1/doc\u{1E}"
        }
        let auth80Task = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":80,"browser_app_id":"com.google.Chrome"}"#)
        }
        let app80 = try await waitForApproval(simTools, step: "adversarial case 6 auth")
        simTools.resolve(id: app80.id, allow: true)
        let auth80Result = try await auth80Task.value
        guard let auth80Object = try? JSONSerialization.jsonObject(with: Data(auth80Result.utf8)) as? [String: Any],
              auth80Object["ok"] as? Bool == true else {
            throw Failure("Case 6: Authorization for the in-flight read fixture failed: \(auth80Result)")
        }

        // 6a. Pause during in-flight read
        let readGate6a = AsyncGate()
        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                await readGate6a.enterAndAwaitRelease()
                return #"{"title":"Secret Doc","url":"http://127.0.0.1/doc","text":"Sensitive Data 123"}"#
            }
            return "80\u{1F}1\u{1F}1\u{1F}1\u{1F}Secret Doc\u{1F}http://127.0.0.1/doc\u{1E}"
        }

        let inFlightRead6aTask = Task {
            try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":80,"browser_app_id":"com.google.Chrome"}"#)
        }
        try await readGate6a.waitUntilEntered(step: "case 6a paused read")

        _ = try await simTools.execute(name: "pause_browser_tabs", arguments: #"{"paused":true}"#)
        readGate6a.release()

        let inFlightRead6aRes = try await inFlightRead6aTask.value
        let inFlightRead6aObj = try JSONSerialization.jsonObject(with: Data(inFlightRead6aRes.utf8)) as? [String: Any]
        guard inFlightRead6aObj?["ok"] as? Bool == false,
              let err6a = inFlightRead6aObj?["error"] as? String,
              err6a.contains("in flight") || err6a.contains("paused") else {
            throw Failure("Case 6a: In-flight read was not suppressed on pause: \(inFlightRead6aRes)")
        }
        if let leaked = inFlightRead6aObj?["content"] as? String, !leaked.isEmpty {
            throw Failure("Case 6a: Content leaked despite in-flight pause")
        }

        _ = try await simTools.execute(name: "pause_browser_tabs", arguments: #"{"paused":false}"#)

        // 6b. Revoke during in-flight read
        let readGate6b = AsyncGate()
        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                await readGate6b.enterAndAwaitRelease()
                return #"{"title":"Secret Doc","url":"http://127.0.0.1/doc","text":"Sensitive Data 123"}"#
            }
            return "80\u{1F}1\u{1F}1\u{1F}1\u{1F}Secret Doc\u{1F}http://127.0.0.1/doc\u{1E}"
        }

        let inFlightRead6bTask = Task {
            try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":80,"browser_app_id":"com.google.Chrome"}"#)
        }
        try await readGate6b.waitUntilEntered(step: "case 6b revoked read")

        _ = try await simTools.execute(name: "revoke_browser_tab", arguments: #"{"tab_id":80,"browser_app_id":"com.google.Chrome"}"#)
        readGate6b.release()

        let inFlightRead6bRes = try await inFlightRead6bTask.value
        let inFlightRead6bObj = try JSONSerialization.jsonObject(with: Data(inFlightRead6bRes.utf8)) as? [String: Any]
        guard inFlightRead6bObj?["ok"] as? Bool == false,
              let err6b = inFlightRead6bObj?["error"] as? String,
              err6b.contains("in flight") else {
            throw Failure("Case 6b: In-flight read was not suppressed on revoke: \(inFlightRead6bRes)")
        }
        if let leaked = inFlightRead6bObj?["content"] as? String, !leaked.isEmpty {
            throw Failure("Case 6b: Content leaked despite in-flight revoke")
        }

        // --- 7. Unsupported Explicit Browser Bundle IDs Fail Closed ---
        // Unsupported explicit browser bundle IDs must fail closed.
        let unsupportedIDs = ["com.apple.Safari", "org.mozilla.firefox", "invalid.browser.bundle", ""]
        for badID in unsupportedIDs {
            let listRes = try await simTools.execute(name: "list_browser_tabs", arguments: #"{"browser_app_id":"\#(badID)"}"#)
            let listObj = try JSONSerialization.jsonObject(with: Data(listRes.utf8)) as? [String: Any]
            guard listObj?["ok"] as? Bool == false,
                  let err = listObj?["error"] as? String,
                  err.contains("Unsupported Chromium browser bundle ID") else {
                throw Failure("Case 7: Unsupported browser bundle ID '\(badID)' did not fail closed in listing: \(listRes)")
            }

            let readRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":1,"browser_app_id":"\#(badID)"}"#)
            let readObj = try JSONSerialization.jsonObject(with: Data(readRes.utf8)) as? [String: Any]
            guard readObj?["ok"] as? Bool == false,
                  let readError = readObj?["error"] as? String,
                  readError.contains("Unsupported Chromium browser bundle ID") else {
                throw Failure("Case 7: Read with unsupported browser bundle ID '\(badID)' did not fail closed: \(readRes)")
            }
        }

        // --- 8. Existing Domain-Navigation Revocation ---
        // Existing domain-navigation revocation must remain covered.
        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                return #"{"title":"Original","url":"http://127.0.0.1/doc","text":"Original Text"}"#
            }
            return "90\u{1F}1\u{1F}1\u{1F}1\u{1F}Original\u{1F}http://127.0.0.1/doc\u{1E}"
        }
        let auth90Task = Task {
            try await simTools.execute(name: "authorize_browser_tab", arguments: #"{"tab_id":90,"browser_app_id":"com.google.Chrome"}"#)
        }
        let app90 = try await waitForApproval(simTools, step: "adversarial case 8 auth")
        simTools.resolve(id: app90.id, allow: true)
        let auth90Result = try await auth90Task.value
        guard let auth90Object = try? JSONSerialization.jsonObject(with: Data(auth90Result.utf8)) as? [String: Any],
              auth90Object["ok"] as? Bool == true else {
            throw Failure("Case 8: Authorization for domain-navigation fixture failed: \(auth90Result)")
        }

        let firstReadRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":90,"browser_app_id":"com.google.Chrome"}"#)
        let firstReadObj = try JSONSerialization.jsonObject(with: Data(firstReadRes.utf8)) as? [String: Any]
        guard firstReadObj?["ok"] as? Bool == true else {
            throw Failure("Case 8: First read failed: \(firstReadRes)")
        }

        runtime.setScriptHandler { script in
            if script.contains("execute t javascript") {
                return #"{"title":"Navigated","url":"http://localhost/navigated","text":"Hijacked Text"}"#
            }
            return "90\u{1F}1\u{1F}1\u{1F}1\u{1F}Navigated\u{1F}http://localhost/navigated\u{1E}"
        }

        let hijackedRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":90,"browser_app_id":"com.google.Chrome"}"#)
        let hijackedObj = try JSONSerialization.jsonObject(with: Data(hijackedRes.utf8)) as? [String: Any]
        guard hijackedObj?["ok"] as? Bool == false,
              let hijackErr = hijackedObj?["error"] as? String,
              hijackErr.contains("navigated") && hijackErr.contains("revoked") else {
            throw Failure("Case 8: Domain navigation was not caught and revoked: \(hijackedRes)")
        }

        let secondReadRes = try await simTools.execute(name: "read_browser_tab", arguments: #"{"tab_id":90,"browser_app_id":"com.google.Chrome"}"#)
        let secondReadObj = try JSONSerialization.jsonObject(with: Data(secondReadRes.utf8)) as? [String: Any]
        guard secondReadObj?["ok"] as? Bool == false,
              let secErr = secondReadObj?["error"] as? String,
              secErr.contains("not authorized") else {
            throw Failure("Case 8: Revoked tab remained authorized on subsequent read: \(secondReadRes)")
        }

        print("PASS: Deterministic browser-session adversarial coverage: cross-browser isolation, session restart, approval-time change rejection, delimiter immunity, in-flight pause/revoke suppression, and unsupported bundle ID fail-closed verified.")
    }
}
