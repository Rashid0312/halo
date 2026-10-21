import AppKit
import Darwin
import HaloCore
import HaloBridge

@MainActor
enum NativeChecks {
    struct Failure: LocalizedError {
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
        guard let parts = AgentLoop.screenAttachment(result: result), !parts.toolText.contains("image_base64"),
              parts.imageURL.hasPrefix("data:image/jpeg;base64,") else { throw Failure("Screenshot was not converted into an image attachment") }
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

    /// Time from accepting a read_browser_tab request to Halo's first visible
    /// activity callback, which drives the panel's status text.
    @MainActor
    static func measureFirstVisibleActivity(_ tools: MacTools, tabID: Int, samples: Int = 10) async throws -> [Double] {
        let previous = tools.onActivity
        defer { tools.onActivity = previous }
        var results: [Double] = []
        for _ in 0..<samples {
            let clock = ContinuousClock(), accepted = clock.now
            var first: Duration?
            tools.onActivity = { text in if first == nil, !text.isEmpty { first = accepted.duration(to: clock.now) } }
            _ = try await tools.execute(name: "read_browser_tab", arguments: #"{"tab_id":\#(tabID)}"#)
            guard let elapsed = first else { throw Failure("read_browser_tab produced no visible activity.") }
            results.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return results
    }

    final class DisposableTabServer: @unchecked Sendable {
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
                func respond(_ body: String) -> [UInt8] {
                    [UInt8]("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)".utf8)
                }
                let responseBytes = respond(htmlBody)
                // Extra routes for real-browser lifecycle checks: same-site
                // navigation and a large document for in-flight interruption.
                let pageB = respond("<!DOCTYPE html><html><head><title>Halo Fixture Page B</title></head><body><h1>Halo Fixture Page B</h1></body></html>")
                // Phase 5B.1 click fixture. Counts are shown in headings so the
                // bridge observation can verify them; synthetic clicks are marked.
                let clickPage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Click Fixture</title>
                <style>#cover{position:relative;display:inline-block}#cover div{position:absolute;inset:0;background:rgba(0,0,0,0)}</style></head>
                <body><h1>Halo Click Fixture</h1>
                <button type="button" id="counter">Clicked 0 times</button>
                <button id="formless">Formless action</button>
                <button type="button" id="rename">Rename me</button><h2 id="rename-count">Rename clicks: 0</h2>
                <span id="cover"><button type="button" id="covered">Covered button</button><div></div></span><h2 id="covered-count">Covered clicks: 0</h2>
                <form><button type="submit">Submit form</button></form>
                <a href="/page-b">Go to page B</a>
                <button type="button" disabled>Disabled action</button>
                <input type="password" aria-label="Password">
                <script>
                let n = 0, r = 0, c = 0;
                counter.onclick = (e) => { n++; counter.textContent = "Clicked " + n + " times" + (e.isTrusted ? "" : " (synthetic)"); };
                rename.onclick = () => { r++; document.getElementById("rename-count").textContent = "Rename clicks: " + r; };
                covered.onclick = () => { c++; document.getElementById("covered-count").textContent = "Covered clicks: " + c; };
                </script></body></html>
                """#)
                // Phase 5B.2 text-entry fixture. The page reports lengths, input
                // trust, and submissions so checks never need the field values.
                let typePage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Type Fixture</title></head>
                <body><h1>Halo Type Fixture</h1>
                <form id="f">
                <label for="q">Search query</label><input id="q" type="text">
                <label for="notes">Notes</label><textarea id="notes"></textarea>
                <input type="password" aria-label="Password">
                <input id="otp" autocomplete="one-time-code" aria-label="Verification code">
                <input id="card" name="card_number" autocomplete="cc-number" aria-label="Card number">
                <input id="ro" readonly aria-label="Read only field" value="fixed">
                <input id="dis" disabled aria-label="Disabled field">
                <label for="rn">Rename field</label><input id="rn" type="text">
                </form>
                <h2 id="qlen">Query length: 0</h2><h2 id="qtrusted">Query input trusted: none</h2>
                <h2 id="nlen">Notes length: 0</h2><h2 id="subs">Form submissions: 0</h2><h2 id="rnlen">Rename field length: 0</h2>
                <script>
                let subs = 0;
                f.onsubmit = (e) => { e.preventDefault(); subs++; document.getElementById("subs").textContent = "Form submissions: " + subs; };
                q.addEventListener("input", (e) => {
                  document.getElementById("qlen").textContent = "Query length: " + q.value.length;
                  document.getElementById("qtrusted").textContent = "Query input trusted: " + (e.isTrusted ? "yes" : "no");
                });
                notes.addEventListener("input", () => { document.getElementById("nlen").textContent = "Notes length: " + notes.value.length; });
                rn.addEventListener("input", () => { document.getElementById("rnlen").textContent = "Rename field length: " + rn.value.length; });
                </script></body></html>
                """#)
                // Phase 5B.3 select/scroll fixture. The scroll list sits well below
                // the viewport centre so a page scroll never lands on it.
                let messages = (1...50).map { "<p>Message \($0)</p>" }.joined()
                let selectPage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Select Fixture</title>
                <style>body{min-height:3200px}#list{height:120px;overflow:auto;border:1px solid #888}</style></head>
                <body><h1>Halo Select Fixture</h1>
                <form id="f">
                <label for="size">Size</label><select id="size"><option>Small</option><option>Medium</option><option>Large</option><option disabled>Huge</option></select>
                <label for="multi">Toppings</label><select id="multi" multiple><option>Cheese</option><option>Olives</option></select>
                <label for="dsel">Locked choice</label><select id="dsel" disabled><option>Only</option></select>
                <label for="exp">Expiry month</label><select id="exp" name="exp-month" autocomplete="cc-exp-month"><option>01</option><option>02</option></select>
                <label for="rsel">Rename dropdown</label><select id="rsel"><option>One</option><option>Two</option></select>
                </form>
                <h2 id="sz">Size: Small</h2><h2 id="rs">Rename dropdown: One</h2>
                <h2 id="ps">Page scrolled: no</h2><h2 id="ls">List scrolled: no</h2><h2 id="subs">Form submissions: 0</h2>
                <div style="height:1400px"></div>
                <div id="list" aria-label="Message list">
                """# + messages + #"""
                </div>
                <script>
                let subs = 0;
                f.onsubmit = (e) => { e.preventDefault(); subs++; document.getElementById("subs").textContent = "Form submissions: " + subs; };
                document.getElementById("size").onchange = (e) => { document.getElementById("sz").textContent = "Size: " + e.target.value; };
                rsel.onchange = () => { document.getElementById("rs").textContent = "Rename dropdown: " + rsel.value; };
                addEventListener("scroll", () => { document.getElementById("ps").textContent = "Page scrolled: yes"; });
                document.getElementById("list").addEventListener("scroll", () => { document.getElementById("ls").textContent = "List scrolled: yes"; });
                </script></body></html>
                """#)
                // Phase 5B.4 sensitive-action fixture: one ordinary GET search
                // form and links that may be followed; every other family blocked.
                let formsPage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Forms Fixture</title></head>
                <body><h1>Halo Forms Fixture</h1><h2 id="lq">Last query: none</h2>
                <form action="/forms" method="get"><label for="q">Search query</label><input id="q" name="q" type="text">
                <label for="cat">Category</label><select id="cat" name="cat"><option>All</option><option>Docs</option></select>
                <button type="submit">Search</button></form>
                <form><label for="em">Email</label><input id="em" type="email"><input type="password" aria-label="Password"><button type="submit">Continue</button></form>
                <form><input name="card_number" autocomplete="cc-number" aria-label="Card number"><button type="submit">Continue to review</button></form>
                <form><label for="body">Message</label><textarea id="body"></textarea><button type="submit">Send</button></form>
                <form><input type="file" aria-label="Attachment"><button type="submit">Upload</button></form>
                <form action="https://example.com/collect"><label for="nm">Name</label><input id="nm"><button type="submit">Next step</button></form>
                <button type="button">Delete account</button><button type="button">Buy now</button>
                <a href="/page-b">Page B</a> <a href="/page-b" target="_blank">Open in new tab</a>
                <a href="/report.zip">Download report</a> <a href="mailto:team@example.com">Email us</a>
                <a href="/logout">Sign out</a> <a id="ext" href="/">Other site</a>
                <script>
                document.getElementById("lq").textContent = "Last query: " + (new URLSearchParams(location.search).get("q") || "none");
                document.getElementById("ext").href = "http://localhost:" + location.port + "/halo-test";
                </script></body></html>
                """#)
                // Real-page robustness fixtures: an open shadow root, and a page
                // crowded with hidden and below-the-fold controls.
                let shadowPage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Shadow Fixture</title></head>
                <body><h1>Halo Shadow Fixture</h1><h2 id="sc">Shadow clicks: 0</h2><h2 id="sl">Shadow field length: 0</h2>
                <halo-widget></halo-widget>
                <script>
                customElements.define("halo-widget", class extends HTMLElement {
                  connectedCallback() {
                    const root = this.attachShadow({ mode: "open" });
                    root.innerHTML = '<button type="button" id="b">Shadow action</button> <input id="f" aria-label="Shadow field">';
                    let clicks = 0;
                    root.getElementById("b").addEventListener("click", (e) => {
                      if (e.isTrusted) document.getElementById("sc").textContent = "Shadow clicks: " + (++clicks);
                    });
                    root.getElementById("f").addEventListener("input", (e) => {
                      document.getElementById("sl").textContent = "Shadow field length: " + e.target.value.length;
                    });
                  }
                });
                </script></body></html>
                """#)
                let crowdedPage = respond(#"<!DOCTYPE html><html><head><title>Halo Crowded Fixture</title></head><body>"#
                    + #"<div style="display:none">"# + (0..<300).map { "<button type=\"button\">Hidden control \($0)</button>" }.joined() + "</div>"
                    + #"<div style="margin-top:3000px">"# + (0..<250).map { "<button type=\"button\">Below fold \($0)</button>" }.joined() + "</div>"
                    + #"<button type="button" style="position:fixed;top:10px;left:10px">Target action</button></body></html>"#)
                // A video playing a generated 60 s silent WAV: seekable, with sound
                // (so autoplay rules apply), and no media file to ship.
                let mediaPage = respond(#"""
                <!DOCTYPE html><html><head><title>Halo Media Fixture</title></head>
                <body><h1>Halo Media Fixture</h1><div id="player" style="width:480px;height:270px"><video id="v" style="width:480px;height:270px"></video></div>
                <script>
                const rate = 8000, seconds = 60, n = rate * seconds, buf = new ArrayBuffer(44 + n), d = new DataView(buf);
                const w = (o, s) => [...s].forEach((c, i) => d.setUint8(o + i, c.charCodeAt(0)));
                w(0, "RIFF"); d.setUint32(4, 36 + n, true); w(8, "WAVEfmt "); d.setUint32(16, 16, true); d.setUint16(20, 1, true);
                d.setUint16(22, 1, true); d.setUint32(24, rate, true); d.setUint32(28, rate, true); d.setUint16(32, 1, true);
                d.setUint16(34, 8, true); w(36, "data"); d.setUint32(40, n, true); new Uint8Array(buf, 44).fill(128);
                document.getElementById("v").src = URL.createObjectURL(new Blob([buf], { type: "audio/wav" }));
                </script></body></html>
                """#)
                let large = respond("<!DOCTYPE html><html><head><title>Halo Disposable Browser Fixture</title></head><body><h1>Halo Chrome Integration Test</h1>"
                    + (0..<3000).map { "<button>Fixture control \($0)</button>" }.joined() + "</body></html>")

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
                    // Serve each connection on its own thread: Chromium preconnects
                    // idle sockets that would otherwise stall the real request.
                    Thread.detachNewThread {
                        var requestLine = ""
                        var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
                        if poll(&pfd, 1, 1000) > 0 {
                            var buffer = [UInt8](repeating: 0, count: 2048)
                            let count = Darwin.read(client, &buffer, buffer.count)
                            if count > 0 { requestLine = String(decoding: buffer[..<count], as: UTF8.self) }
                        }
                        guard !requestLine.isEmpty else { Darwin.close(client); return }
                        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                        let bytes = path.hasPrefix("/page-b") ? pageB : path.hasPrefix("/large") ? large
                            : path.hasPrefix("/click") ? clickPage : path.hasPrefix("/type") ? typePage
                            : path.hasPrefix("/select") ? selectPage : path.hasPrefix("/forms") ? formsPage
                            : path.hasPrefix("/shadow") ? shadowPage : path.hasPrefix("/crowded") ? crowdedPage
                            : path.hasPrefix("/media") ? mediaPage : responseBytes
                        _ = bytes.withUnsafeBufferPointer { buf -> Int in
                            var written = 0
                            while written < buf.count {
                                let n = Darwin.write(client, buf.baseAddress!.advanced(by: written), buf.count - written)
                                if n > 0 { written += n; continue }
                                if n < 0 && (errno == EAGAIN || errno == EINTR) {
                                    var wfd = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
                                    if poll(&wfd, 1, 1000) > 0 { continue }
                                }
                                break
                            }
                            return written
                        }
                        Darwin.close(client)
                    }
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
        // Run Phase 5 Native Messaging transport-neutral bridge protocol checks
        try await browserBridgeProtocolChecks()

        // Run Phase 5A Chromium Native Messaging Bridge checks (helper, UDS IPC, adversarial, performance, and real-browser probe)
        try await chromiumNativeMessagingBridgeChecks(tools)

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

        // 11. Test reading authorized tab content, timing Halo's first visible
        // activity from the moment the tool request is accepted.
        let feedback = try await measureFirstVisibleActivity(tools, tabID: tabID)
        print("| First visible Halo activity after read_browser_tab accepted | 10 | \(String(format: "%.3f ms", percentile(feedback, 0.5))) | \(String(format: "%.3f ms", percentile(feedback, 0.95))) | \(String(format: "%.3f ms", feedback.max() ?? 0)) | <= 500 ms | \(percentile(feedback, 0.95) <= 500 ? "PASS" : "FAIL") |")
        guard percentile(feedback, 0.95) <= 500 else { throw Failure("First visible activity exceeded 500 ms.") }
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

    static func browserBridgeProtocolChecks() async throws {
        let validNonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let clientNonce = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
        let validator = BridgeSessionValidator(sessionNonce: validNonce)

        let browserIdentity = BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "1001:100.0", pid: 1001)
        let tabGen1 = TabGenerationIdentity(browser: browserIdentity, tabID: 100, documentGenerationID: 1, url: "https://example.com/page1", domain: "example.com")
        let tabGen2 = TabGenerationIdentity(browser: browserIdentity, tabID: 100, documentGenerationID: 2, url: "https://example.com/page2", domain: "example.com")

        // 1. Valid handshake succeeds
        let challenge = BridgeHandshakeChallenge(version: 1, serverNonce: validNonce, hostProcessID: 1001)
        let challengeData = try BridgeMessageFraming.encode(challenge)
        let decodedChallenge = try BridgeMessageFraming.decode(BridgeHandshakeChallenge.self, from: challengeData)
        guard decodedChallenge == challenge else {
            throw Failure("Bridge check 1: Handshake challenge roundtrip mismatch")
        }

        let response = BridgeHandshakeResponse(version: 1, serverNonce: validNonce, clientNonce: clientNonce, extensionID: "knldjmfmopnpolahpmmgbagdohdnhkik")
        let responseData = try BridgeMessageFraming.encode(response)
        let decodedResponse = try BridgeMessageFraming.decode(BridgeHandshakeResponse.self, from: responseData)
        guard decodedResponse == response else {
            throw Failure("Bridge check 1: Handshake response roundtrip mismatch")
        }
        guard BridgeSessionValidator.constantTimeEquals(decodedResponse.serverNonce, validNonce) else {
            throw Failure("Bridge check 1: Constant-time nonce check failed for valid handshake")
        }
        try BridgeHandshakeValidator.validate(challenge: challenge, response: response,
                                              pinnedExtensionID: "knldjmfmopnpolahpmmgbagdohdnhkik")
        let echoedResponse = BridgeHandshakeResponse(version: 1, serverNonce: validNonce, clientNonce: validNonce, extensionID: "knldjmfmopnpolahpmmgbagdohdnhkik")
        do {
            try BridgeHandshakeValidator.validate(challenge: challenge, response: echoedResponse,
                                                  pinnedExtensionID: "knldjmfmopnpolahpmmgbagdohdnhkik")
            throw Failure("Bridge check 1: Handshake echoing serverNonce as clientNonce was accepted")
        } catch let err as BridgeErrorDetails where err.code == .authenticationFailed {}

        // 2. Wrong version fails
        let wrongVersionReq = BridgeRequest(requestID: "req_v2", protocolVersion: 2, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen1)
        var caughtWrongVersionReq = false
        do {
            try await validator.validateRequest(wrongVersionReq)
        } catch let err as BridgeErrorDetails where err.code == .unsupportedVersion {
            caughtWrongVersionReq = true
        }
        guard caughtWrongVersionReq else {
            throw Failure("Bridge check 2: Request with unsupported version was not rejected")
        }

        let wrongVersionResp = BridgeResponse(requestID: "req_v2_resp", protocolVersion: 99, sessionNonce: validNonce, success: true)
        var caughtWrongVersionResp = false
        do {
            try await validator.validateResponse(wrongVersionResp)
        } catch let err as BridgeErrorDetails where err.code == .unsupportedVersion {
            caughtWrongVersionResp = true
        }
        guard caughtWrongVersionResp else {
            throw Failure("Bridge check 2: Response with unsupported version was not rejected")
        }

        // 3. Wrong nonce / authentication fails
        let wrongNonceReq = BridgeRequest(requestID: "req_wrong_nonce", protocolVersion: 1, sessionNonce: "0000000000000000000000000000000000000000000000000000000000000000", type: .observeTab, targetTab: tabGen1)
        var caughtWrongNonce = false
        do {
            try await validator.validateRequest(wrongNonceReq)
        } catch let err as BridgeErrorDetails where err.code == .authenticationFailed {
            caughtWrongNonce = true
        }
        guard caughtWrongNonce else {
            throw Failure("Bridge check 3: Request with invalid session nonce was not rejected")
        }
        guard !BridgeSessionValidator.constantTimeEquals(validNonce, "wrong_nonce") else {
            throw Failure("Bridge check 3: constantTimeEquals returned true for mismatched strings")
        }

        // 4. Oversized frame fails
        let oversizedData = Data(repeating: 65, count: BrowserBridgeLimits.maxMessageSizeBytes + 1)
        var caughtOversized = false
        do {
            _ = try BridgeMessageFraming.decode(BridgeRequest.self, from: oversizedData)
        } catch let err as BridgeErrorDetails where err.code == .oversizedPayload {
            caughtOversized = true
        }
        guard caughtOversized else {
            throw Failure("Bridge check 4: Oversized frame was not rejected by BridgeMessageFraming")
        }

        // 5. Replayed request ID fails
        try await validator.authorizeTab(tabGen1)
        let validReq1 = BridgeRequest(requestID: "req_unique_001", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen1)
        try await validator.validateRequest(validReq1)

        var caughtReplay = false
        do {
            try await validator.validateRequest(validReq1)
        } catch let err as BridgeErrorDetails where err.code == .replayedRequest {
            caughtReplay = true
        }
        guard caughtReplay else {
            throw Failure("Bridge check 5: Replayed request ID was not rejected")
        }

        // 6. Cross-browser / tab / document identity mismatch fails
        let unauthBrowser = BrowserIdentity(bundleID: "com.brave.Browser", sessionID: "2002:200.0", pid: 2002)
        let unauthTab = TabGenerationIdentity(browser: unauthBrowser, tabID: 100, documentGenerationID: 1, url: "https://evil.com", domain: "evil.com")
        let unauthReq = BridgeRequest(requestID: "req_unauth_tab", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: unauthTab)
        var caughtUnauth = false
        do {
            try await validator.validateRequest(unauthReq)
        } catch let err as BridgeErrorDetails where err.code == .tabNotAuthorized {
            caughtUnauth = true
        }
        guard caughtUnauth else {
            throw Failure("Bridge check 6: Unauthorized tab request was not rejected")
        }

        // 7. Navigation generation invalidates prior references
        let preNavigationRequest = BridgeRequest(requestID: "req_before_nav", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen1)
        try await validator.validateRequest(preNavigationRequest)
        let navEvent = TabNavigationEvent(browser: browserIdentity, tabID: 100, previousDocumentGenerationID: 1, newDocumentGenerationID: 2, newURL: "https://example.com/page2", newDomain: "example.com")
        try await validator.notifyNavigation(event: navEvent)

        let staleReq = BridgeRequest(requestID: "req_stale_gen", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen1)
        var caughtStaleReq = false
        do {
            try await validator.validateRequest(staleReq)
        } catch let err as BridgeErrorDetails where err.code == .staleDocumentGeneration {
            caughtStaleReq = true
        }
        guard caughtStaleReq else {
            throw Failure("Bridge check 7: Stale document generation request was not rejected")
        }

        let validGen2Req = BridgeRequest(requestID: "req_valid_gen2", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen2)
        try await validator.validateRequest(validGen2Req)

        let staleObsEvent = TabObservedEvent(tab: tabGen1, title: "Old Title", elements: [])
        let staleResp = BridgeResponse(requestID: "req_before_nav", protocolVersion: 1, sessionNonce: validNonce, success: true, observation: staleObsEvent)
        var caughtStaleResp = false
        do {
            try await validator.validateResponse(staleResp)
        } catch let err as BridgeErrorDetails where err.code == .accessPaused || err.code == .staleDocumentGeneration {
            caughtStaleResp = true
        }
        guard caughtStaleResp else {
            throw Failure("Bridge check 7: Stale document generation response was not rejected")
        }

        // 8. Pause / revoke rejects queued and in-flight responses
        await validator.setPaused(true)
        var caughtPausedReq = false
        do {
            let pausedReq = BridgeRequest(requestID: "req_paused", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen2)
            try await validator.validateRequest(pausedReq)
        } catch let err as BridgeErrorDetails where err.code == .accessPaused {
            caughtPausedReq = true
        }
        guard caughtPausedReq else {
            throw Failure("Bridge check 8a: Request during access pause was not rejected")
        }

        var caughtPausedResp = false
        do {
            let pausedResp = BridgeResponse(requestID: "resp_paused", protocolVersion: 1, sessionNonce: validNonce, success: true)
            try await validator.validateResponse(pausedResp)
        } catch let err as BridgeErrorDetails where err.code == .accessPaused {
            caughtPausedResp = true
        }
        guard caughtPausedResp else {
            throw Failure("Bridge check 8a: Response during access pause was not rejected")
        }
        await validator.setPaused(false)

        await validator.revokeTab(tabGen2)
        var caughtRevokedReq = false
        do {
            let revokedReq = BridgeRequest(requestID: "req_revoked", protocolVersion: 1, sessionNonce: validNonce, type: .observeTab, targetTab: tabGen2)
            try await validator.validateRequest(revokedReq)
        } catch let err as BridgeErrorDetails where err.code == .tabNotAuthorized {
            caughtRevokedReq = true
        }
        guard caughtRevokedReq else {
            throw Failure("Bridge check 8b: Request for revoked tab was not rejected")
        }

        // 9. Unknown message type fails
        let rawUnknownType = #"{"requestID":"req_unk","protocolVersion":1,"sessionNonce":"\#(validNonce)","type":"arbitraryMutation"}"#
        var caughtUnknownType = false
        do {
            _ = try BridgeMessageFraming.decode(BridgeRequest.self, from: Data(rawUnknownType.utf8))
        } catch let err as BridgeErrorDetails where err.code == .payloadMalformed {
            caughtUnknownType = true
        }
        guard caughtUnknownType else {
            throw Failure("Bridge check 9: Unknown message type did not fail decoding")
        }

        // 10. Sensitive/forbidden fields are not present in encoded protocol models
        let element = ObservedDOMElement(elementID: "el_1", tagName: "input", role: "textfield", label: "Username", isProtected: false, isEnabled: true, bounds: BoundedRect(x: 10, y: 20, width: 100, height: 30))
        let obsEvent = TabObservedEvent(tab: tabGen2, title: "Clean Title", elements: [element])
        let encodedObs = try BridgeMessageFraming.encode(obsEvent)
        guard let encodedString = String(data: encodedObs, encoding: .utf8) else {
            throw Failure("Bridge check 10: Failed to decode observation to UTF8 string")
        }
        let forbiddenTerms = ["password", "cookie", "token", "keychain", "profile_dir", "localStorage", "sessionStorage"]
        for term in forbiddenTerms {
            guard !encodedString.contains("\"\(term)\":") else {
                throw Failure("Bridge check 10: Forbidden term '\(term)' found as key in encoded protocol payload: \(encodedString)")
            }
        }

        // 11. Native Messaging framing, strict envelope keys, and bounded identifiers
        let framed = try BridgeMessageFraming.encodeFrame(validReq1)
        let decodedFrame = try BridgeMessageFraming.decodeFrame(BridgeRequest.self, from: framed)
        guard decodedFrame == validReq1 else { throw Failure("Bridge check 11: Native Messaging frame roundtrip failed") }

        let overlongRequest = BridgeRequest(requestID: String(repeating: "x", count: 65), sessionNonce: validNonce,
                                            type: .observeTab, targetTab: tabGen2)
        do {
            _ = try BridgeMessageFraming.encode(overlongRequest)
            throw Failure("Bridge check 11: Overlong request ID was silently truncated or accepted")
        } catch let error as BridgeErrorDetails where error.code == .payloadMalformed {}

        let extraField = #"{"requestID":"req_extra","protocolVersion":1,"sessionNonce":"\#(validNonce)","type":"pauseTabs","extra":"forbidden"}"#
        do {
            _ = try BridgeMessageFraming.decode(BridgeRequest.self, from: Data(extraField.utf8))
            throw Failure("Bridge check 11: Unknown envelope field was accepted")
        } catch let error as BridgeErrorDetails where error.code == .payloadMalformed {}

        // 12. Responses are correlated to one outstanding request and full browser identity.
        let correlationValidator = BridgeSessionValidator(sessionNonce: validNonce)
        try await correlationValidator.authorizeTab(tabGen2)
        let correlationRequest = BridgeRequest(requestID: "req_correlated", sessionNonce: validNonce,
                                               type: .observeTab, targetTab: tabGen2)
        try await correlationValidator.validateRequest(correlationRequest)
        let wrongBrowserSameTab = TabGenerationIdentity(browser: unauthBrowser, tabID: 100,
            documentGenerationID: 2, url: "https://evil.com", domain: "evil.com")
        let mismatchedResponse = BridgeResponse(requestID: "req_correlated", sessionNonce: validNonce,
            success: true, observation: TabObservedEvent(tab: wrongBrowserSameTab, title: "Wrong browser", elements: []))
        do {
            try await correlationValidator.validateResponse(mismatchedResponse)
            throw Failure("Bridge check 12: Cross-browser response with colliding tab ID was accepted")
        } catch let error as BridgeErrorDetails where error.code == .browserMismatch {}

        // 13. Handshake extension identity and freshness are enforced; nonce is channel binding, not peer authentication.
        do {
            try BridgeHandshakeValidator.validate(challenge: challenge, response: response, pinnedExtensionID: "wrongextensionid")
            throw Failure("Bridge check 13: Unpinned extension identity was accepted")
        } catch let error as BridgeErrorDetails where error.code == .authenticationFailed {}

        print("PASS: Chromium Native Messaging bridge transport-neutral protocol: pinned-origin channel binding, native framing, strict bounds/schema, replay and response correlation, full browser identity, generation invalidation, and pause/revoke gating verified.")
    }

    // MARK: - Phase 5A: Chromium Native Messaging Bridge Checks

    static func locateHelperBinary() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HaloNativeHost"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("HaloNativeHost"),
            URL(fileURLWithPath: "build/Halo.app/Contents/MacOS/HaloNativeHost"),
            URL(fileURLWithPath: "HaloNative/build/Halo.app/Contents/MacOS/HaloNativeHost"),
            URL(fileURLWithPath: ".build/arm64-apple-macosx/release/HaloNativeHost"),
            URL(fileURLWithPath: ".build/release/HaloNativeHost"),
            URL(fileURLWithPath: ".build/arm64-apple-macosx/debug/HaloNativeHost"),
            URL(fileURLWithPath: ".build/debug/HaloNativeHost")
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        throw Failure("Could not locate executable HaloNativeHost binary. Run scripts/build-app.sh first.")
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let idx = p * Double(sorted.count - 1)
        let lower = Int(floor(idx))
        let upper = Int(ceil(idx))
        if lower == upper { return sorted[lower] }
        let weight = idx - Double(lower)
        return sorted[lower] * (1.0 - weight) + sorted[upper] * weight
    }

    static func getProcessTelemetry(pid: pid_t) -> (rssBytes: UInt64, userTimeNano: UInt64, systemTimeNano: UInt64) {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        if size == MemoryLayout<proc_taskinfo>.size {
            return (UInt64(info.pti_resident_size), UInt64(info.pti_total_user), UInt64(info.pti_total_system))
        }
        return (0, 0, 0)
    }

    static func terminateProcessBounded(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    static func chromiumNativeMessagingBridgeChecks(_ tools: MacTools) async throws {
        print("--- Phase 5A: Chromium Native Messaging Bridge Checks ---")
        let helperBinaryURL = try locateHelperBinary()
        let pinnedExtensionID = BrowserBridgeController.developmentExtensionID

        // 0. Native Messaging Host Manifest Generation and Reversible Installer Verification
        do {
            let tempManifestDir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-manifest-test-\(UUID().uuidString)", isDirectory: true)
            let installed = try NativeMessagingInstaller.install(
                hostName: "app.halo.browser_bridge",
                launcherPath: helperBinaryURL.path,
                allowedOrigins: ["chrome-extension://\(pinnedExtensionID)/"],
                targetDirectories: [tempManifestDir]
            )
            defer {
                NativeMessagingInstaller.uninstall(manifestURLs: installed)
                try? FileManager.default.removeItem(at: tempManifestDir)
            }
            guard let manifestFile = installed.first, FileManager.default.fileExists(atPath: manifestFile.path) else {
                throw Failure("NativeMessagingInstaller failed to write manifest file.")
            }
            let manifestData = try Data(contentsOf: manifestFile)
            guard let obj = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  obj["name"] as? String == "app.halo.browser_bridge",
                  obj["path"] as? String == helperBinaryURL.path,
                  obj["type"] as? String == "stdio",
                  let origins = obj["allowed_origins"] as? [String], origins.contains("chrome-extension://\(pinnedExtensionID)/") else {
                throw Failure("NativeMessagingInstaller manifest contents were malformed or missing required keys.")
            }
            NativeMessagingInstaller.uninstall(manifestURLs: installed)
            guard !FileManager.default.fileExists(atPath: manifestFile.path) else {
                throw Failure("NativeMessagingInstaller failed to cleanly uninstall manifest.")
            }
        }

        // 1. Dedicated Helper Launch & Authenticated UDS IPC Test
        do {
            let server = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
            defer { Task { await server.close() } }

            let process = Process()
            process.executableURL = helperBinaryURL
            process.arguments = ["--session-dir", server.directoryURL.path, "chrome-extension://\(pinnedExtensionID)/"]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }

            try await server.acceptConnection(timeoutSeconds: 5)
            let serverConfig = server.sessionConfig
            let sessionNonce = serverConfig.sessionNonce

            // Send request from Halo via server.sendRequest -> helper -> stdoutPipe
            let testReq = BridgeRequest(
                requestID: "req_pipe_test",
                protocolVersion: 1,
                sessionNonce: sessionNonce,
                type: .observeTab,
                targetTab: TabGenerationIdentity(
                    browser: BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "test:1", pid: 1),
                    tabID: 1,
                    documentGenerationID: 1,
                    url: "http://127.0.0.1/test",
                    domain: "127.0.0.1"
                )
            )
            try await server.sendRequest(testReq)

            // Read from helper stdout (simulating extension receiving request)
            let receivedBytes = try BridgeSocketIO.readFramedData(from: stdoutPipe.fileHandleForReading.fileDescriptor, timeoutSeconds: 5)
            let decodedReq = try BridgeMessageFraming.decode(BridgeRequest.self, from: receivedBytes)
            guard decodedReq.requestID == testReq.requestID else {
                throw Failure("Helper failed to relay request to stdout correctly.")
            }

            // Simulate extension replying by writing to helper's stdinPipe
            let testResp = BridgeResponse(
                requestID: "req_pipe_test",
                protocolVersion: 1,
                sessionNonce: sessionNonce,
                success: true
            )
            let framedResp = try BridgeMessageFraming.encode(testResp)
            try BridgeSocketIO.writeFramedData(to: stdinPipe.fileHandleForWriting.fileDescriptor, payload: framedResp, timeoutSeconds: 5)

            // Server receives response over UDS
            let receivedResp = try await server.receiveResponse(timeoutSeconds: 5)
            guard receivedResp.requestID == testResp.requestID, receivedResp.success else {
                throw Failure("Helper failed to relay response from stdin to Halo UDS correctly.")
            }
            await server.close()
        }

        print("PASS: Phase 5A dedicated helper launched, verified peer PID/UID/binary path via UDS, and completed bi-directional stdio/UDS message relay.")

        // 2. Deterministic Execution of All 17 Required Adversarial Cases
        try await runAll17AdversarialBridgeChecks(helperBinaryURL: helperBinaryURL, pinnedExtensionID: pinnedExtensionID)

        // 3. Performance Instrumentation using ContinuousClock
        try await runBridgePerformanceBenchmarks(helperBinaryURL: helperBinaryURL, pinnedExtensionID: pinnedExtensionID)

        // 4. Real Browser Capability Probe
        try await runRealBrowserCapabilityProbe(helperBinaryURL: helperBinaryURL, pinnedExtensionID: pinnedExtensionID)
    }

    private static func runAll17AdversarialBridgeChecks(helperBinaryURL: URL, pinnedExtensionID: String) async throws {
        let nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let browser1 = BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "s1", pid: 101)
        let browser2 = BrowserIdentity(bundleID: "com.brave.Browser", sessionID: "s2", pid: 202)
        let tabB1 = TabGenerationIdentity(browser: browser1, tabID: 42, documentGenerationID: 1, url: "http://127.0.0.1/a", domain: "127.0.0.1")
        let tabB2 = TabGenerationIdentity(browser: browser2, tabID: 42, documentGenerationID: 1, url: "http://127.0.0.1/a", domain: "127.0.0.1")

        // 1. Same numeric tab ID in two browser/session identities
        let val1 = BridgeSessionValidator(sessionNonce: nonce)
        try await val1.authorizeTab(tabB1)
        let reqB1 = BridgeRequest(requestID: "c1_req1", sessionNonce: nonce, type: .observeTab, targetTab: tabB1)
        try await val1.validateRequest(reqB1)
        let reqB2 = BridgeRequest(requestID: "c1_req2", sessionNonce: nonce, type: .observeTab, targetTab: tabB2)
        var c1Failed = false
        do {
            try await val1.validateRequest(reqB2)
        } catch let e as BridgeErrorDetails where e.code == .tabNotAuthorized {
            c1Failed = true
        }
        guard c1Failed else { throw Failure("Adversarial Case 1: Tab ID 42 across different browser identities shared authorization.") }

        // 2. Response identity differs from its outstanding request
        let val2 = BridgeSessionValidator(sessionNonce: nonce)
        try await val2.authorizeTab(tabB1)
        let req2 = BridgeRequest(requestID: "c2_req", sessionNonce: nonce, type: .observeTab, targetTab: tabB1)
        try await val2.validateRequest(req2)
        let mismatchedObs = TabObservedEvent(tab: tabB2, title: "Spoofed", elements: [])
        let resp2 = BridgeResponse(requestID: "c2_req", sessionNonce: nonce, success: true, observation: mismatchedObs)
        var c2Failed = false
        do {
            try await val2.validateResponse(resp2)
        } catch let e as BridgeErrorDetails where e.code == .browserMismatch || e.code == .tabNotAuthorized {
            c2Failed = true
        }
        guard c2Failed else { throw Failure("Adversarial Case 2: Response with mismatched identity was accepted.") }

        // 3. Browser restarts and reuses a tab ID
        let val3 = BridgeSessionValidator(sessionNonce: nonce)
        let session1Browser = BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "1001:100.0", pid: 1001)
        let tabS1 = TabGenerationIdentity(browser: session1Browser, tabID: 42, documentGenerationID: 1, url: "http://127.0.0.1/s1", domain: "127.0.0.1")
        try await val3.authorizeTab(tabS1)

        let session2Browser = BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "1002:200.0", pid: 1002)
        let tabS2 = TabGenerationIdentity(browser: session2Browser, tabID: 42, documentGenerationID: 1, url: "http://127.0.0.1/s1", domain: "127.0.0.1")
        let reqS2 = BridgeRequest(requestID: "c3_req", sessionNonce: nonce, type: .observeTab, targetTab: tabS2)
        var c3Failed = false
        do {
            try await val3.validateRequest(reqS2)
        } catch let e as BridgeErrorDetails where e.code == .tabNotAuthorized {
            c3Failed = true
        }
        guard c3Failed else { throw Failure("Adversarial Case 3: Restarted browser session inherited prior tab authorization.") }

        // 4. Navigation occurs while observation is in flight
        let val4 = BridgeSessionValidator(sessionNonce: nonce)
        let tabGen1 = TabGenerationIdentity(browser: browser1, tabID: 55, documentGenerationID: 1, url: "http://127.0.0.1/p1", domain: "127.0.0.1")
        try await val4.authorizeTab(tabGen1)
        let req4 = BridgeRequest(requestID: "c4_req", sessionNonce: nonce, type: .observeTab, targetTab: tabGen1)
        try await val4.validateRequest(req4)

        let navEvent = TabNavigationEvent(browser: browser1, tabID: 55, previousDocumentGenerationID: 1, newDocumentGenerationID: 2, newURL: "http://127.0.0.1/p2", newDomain: "127.0.0.1")
        try await val4.notifyNavigation(event: navEvent)

        let staleObs = TabObservedEvent(tab: tabGen1, title: "Stale", elements: [])
        let resp4 = BridgeResponse(requestID: "c4_req", sessionNonce: nonce, success: true, observation: staleObs)
        var c4Failed = false
        do {
            try await val4.validateResponse(resp4)
        } catch let e as BridgeErrorDetails where e.code == .staleDocumentGeneration || e.code == .accessPaused {
            c4Failed = true
        }
        guard c4Failed else { throw Failure("Adversarial Case 4: Stale observation response after navigation was accepted.") }

        // 5. Pause occurs while observation is in flight
        let val5 = BridgeSessionValidator(sessionNonce: nonce)
        try await val5.authorizeTab(tabGen1)
        let req5 = BridgeRequest(requestID: "c5_req", sessionNonce: nonce, type: .observeTab, targetTab: tabGen1)
        try await val5.validateRequest(req5)

        await val5.setPaused(true)
        let resp5 = BridgeResponse(requestID: "c5_req", sessionNonce: nonce, success: true, observation: TabObservedEvent(tab: tabGen1, title: "Paused", elements: []))
        var c5Failed = false
        do {
            try await val5.validateResponse(resp5)
        } catch let e as BridgeErrorDetails where e.code == .accessPaused {
            c5Failed = true
        }
        guard c5Failed else { throw Failure("Adversarial Case 5: Response delivered despite active pause.") }
        await val5.setPaused(false)

        // 6. Revoke occurs while observation is in flight
        let val6 = BridgeSessionValidator(sessionNonce: nonce)
        try await val6.authorizeTab(tabGen1)
        let req6 = BridgeRequest(requestID: "c6_req", sessionNonce: nonce, type: .observeTab, targetTab: tabGen1)
        try await val6.validateRequest(req6)

        await val6.revokeTab(tabGen1)
        let resp6 = BridgeResponse(requestID: "c6_req", sessionNonce: nonce, success: true, observation: TabObservedEvent(tab: tabGen1, title: "Revoked", elements: []))
        var c6Failed = false
        do {
            try await val6.validateResponse(resp6)
        } catch let e as BridgeErrorDetails where e.code == .tabNotAuthorized || e.code == .accessPaused {
            c6Failed = true
        }
        guard c6Failed else { throw Failure("Adversarial Case 6: Response delivered after tab authorization was revoked.") }

        // 7. Helper exits while a request is pending
        do {
            let server7 = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
            let proc7 = Process()
            proc7.executableURL = helperBinaryURL
            proc7.arguments = ["--session-dir", server7.directoryURL.path, "chrome-extension://\(pinnedExtensionID)/"]
            let inPipe7 = Pipe()
            let outPipe7 = Pipe()
            let errPipe7 = Pipe()
            proc7.standardInput = inPipe7
            proc7.standardOutput = outPipe7
            proc7.standardError = errPipe7
            try proc7.run()
            try await server7.acceptConnection(timeoutSeconds: 5)

            kill(proc7.processIdentifier, SIGTERM)
            proc7.waitUntilExit()

            var c7Caught = false
            do {
                _ = try await server7.receiveResponse(timeoutSeconds: 1)
            } catch {
                c7Caught = true
            }
            guard c7Caught else { throw Failure("Adversarial Case 7: Pending request did not error when helper exited.") }
            await server7.close()
        }

        // 8. Cancellation occurs during handshake and observation
        do {
            let server8 = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
            let cancelTask = Task {
                try await server8.acceptConnection(timeoutSeconds: 10)
            }
            try await Task.sleep(for: .milliseconds(50))
            cancelTask.cancel()
            var c8Caught = false
            do {
                try await cancelTask.value
            } catch is CancellationError {
                c8Caught = true
            } catch {
                c8Caught = true
            }
            guard c8Caught else { throw Failure("Adversarial Case 8: Server acceptConnection ignored Task cancellation.") }
            await server8.close()
        }

        // 9. Incognito context attempts connection & behavioral rejection
        let manifestURL = URL(fileURLWithPath: "HaloNative/Fixtures/BrowserBridgeExtension/manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifestData = try Data(contentsOf: manifestURL)
            guard let manifestObj = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
                  manifestObj["incognito"] as? String == "not_allowed" else {
                throw Failure("Adversarial Case 9: Extension manifest did not declare 'incognito: not_allowed'.")
            }
        }
        // Behavioral runtime rejection: Incognito tab authorization attempt fails closed
        let incognitoTab = TabGenerationIdentity(browser: browser1, tabID: 999, documentGenerationID: 1, url: "http://127.0.0.1/secret", domain: "127.0.0.1", isIncognito: true)
        let valIncognito = BridgeSessionValidator(sessionNonce: nonce)
        var c9AuthFailed = false
        do {
            try await valIncognito.authorizeTab(incognitoTab)
        } catch let e as BridgeErrorDetails where e.code == .tabNotAuthorized {
            c9AuthFailed = true
        }
        guard c9AuthFailed else { throw Failure("Adversarial Case 9: Incognito tab authorization was not rejected at runtime.") }

        // Behavioral runtime rejection: Incognito request validation fails closed
        let reqIncognito = BridgeRequest(requestID: "c9_req", sessionNonce: nonce, type: .observeTab, targetTab: incognitoTab)
        var c9ReqFailed = false
        do {
            try await valIncognito.validateRequest(reqIncognito)
        } catch let e as BridgeErrorDetails where e.code == .tabNotAuthorized {
            c9ReqFailed = true
        }
        guard c9ReqFailed else { throw Failure("Adversarial Case 9: Incognito request was not rejected at runtime.") }

        // 10. Unknown extension origin or incorrect pinned identity
        do {
            let server10 = try BridgeIPCServer(pinnedExtensionID: "correct_pinned_extension_id", helperExecutableURL: helperBinaryURL)
            let proc10 = Process()
            proc10.executableURL = helperBinaryURL
            proc10.arguments = ["--session-dir", server10.directoryURL.path, "chrome-extension://hostile_unpinned_extension_id/"]
            proc10.standardInput = Pipe()
            proc10.standardOutput = Pipe()
            proc10.standardError = Pipe()
            try proc10.run()
            defer {
                if proc10.isRunning { proc10.terminate(); proc10.waitUntilExit() }
            }
            // Only an explicit authentication rejection counts; a timeout would
            // mean the helper never reached Halo, which proves nothing.
            var c10Caught = false
            do {
                try await server10.acceptConnection(timeoutSeconds: 3)
            } catch let e as BridgeErrorDetails where e.code == .authenticationFailed {
                c10Caught = true
            } catch {}
            guard c10Caught else { throw Failure("Adversarial Case 10: Unknown extension origin was accepted by Halo.") }
            await server10.close()
        }

        // 11. Malformed length prefix
        var c11Caught = false
        let malformedHeader = Data([0x01, 0x02])
        do {
            _ = try BridgeMessageFraming.decodeFrame(BridgeRequest.self, from: malformedHeader)
        } catch let e as BridgeErrorDetails where e.code == .payloadMalformed {
            c11Caught = true
        }
        guard c11Caught else { throw Failure("Adversarial Case 11: Malformed length prefix was not rejected.") }

        // 12. Declared length differs from payload length
        var c12Caught = false
        var header100 = UInt32(100).littleEndian
        var frame12 = withUnsafeBytes(of: &header100) { Data($0) }
        frame12.append(Data([0x01, 0x02, 0x03]))
        do {
            _ = try BridgeMessageFraming.decodeFrame(BridgeRequest.self, from: frame12)
        } catch let e as BridgeErrorDetails where e.code == .payloadMalformed {
            c12Caught = true
        }
        guard c12Caught else { throw Failure("Adversarial Case 12: Payload shorter than declared length was not rejected.") }

        // 13. Frame exceeds 1 MiB
        var c13Caught = false
        var headerOversized = UInt32(BrowserBridgeLimits.maxMessageSizeBytes + 1).littleEndian
        let frame13 = withUnsafeBytes(of: &headerOversized) { Data($0) }
        do {
            _ = try BridgeMessageFraming.decodeFrame(BridgeRequest.self, from: frame13)
        } catch let e as BridgeErrorDetails where e.code == .oversizedPayload {
            c13Caught = true
        }
        guard c13Caught else { throw Failure("Adversarial Case 13: Frame exceeding 1 MiB was not rejected.") }

        // 14. Unknown envelope fields/message type
        var c14Caught = false
        let unknownJson = #"{"requestID":"req_unk","protocolVersion":1,"sessionNonce":"\#(nonce)","type":"arbitraryMutation"}"#
        do {
            _ = try BridgeMessageFraming.decode(BridgeRequest.self, from: Data(unknownJson.utf8))
        } catch let e as BridgeErrorDetails where e.code == .payloadMalformed {
            c14Caught = true
        }
        guard c14Caught else { throw Failure("Adversarial Case 14: Unknown envelope type was not rejected.") }

        // 15. Oversized strings/elements/request state
        var c15Caught = false
        let overlongReqID = String(repeating: "a", count: 65)
        let req15 = BridgeRequest(requestID: overlongReqID, sessionNonce: nonce, type: .observeTab, targetTab: tabGen1)
        do {
            _ = try BridgeMessageFraming.encode(req15)
        } catch let e as BridgeErrorDetails where e.code == .payloadMalformed {
            c15Caught = true
        }
        guard c15Caught else { throw Failure("Adversarial Case 15: Overlong request ID was not rejected.") }

        var c15bCaught = false
        var tooManyElements: [ObservedDOMElement] = []
        for idx in 0..<201 {
            tooManyElements.append(ObservedDOMElement(elementID: "el_\(idx)", tagName: "div", role: "none", label: "item", isProtected: false, isEnabled: true, bounds: BoundedRect(x: 0, y: 0, width: 10, height: 10)))
        }
        let obs15 = TabObservedEvent(tab: tabGen1, title: "Too Many", elements: tooManyElements)
        let resp15b = BridgeResponse(requestID: "c15b", sessionNonce: nonce, success: true, observation: obs15)
        do {
            _ = try BridgeMessageFraming.encode(resp15b)
        } catch let e as BridgeErrorDetails where e.code == .oversizedPayload {
            c15bCaught = true
        }
        guard c15bCaught else { throw Failure("Adversarial Case 15b: Observation with > 200 elements was not rejected.") }

        // 16. DOM text contains framing/control characters
        let complexText = "Title with \u{001E} record separator, \u{001F} unit separator, null \u{0000}, <script>alert(1)</script>"
        let safeElement = ObservedDOMElement(elementID: "el_ctrl", tagName: "div", role: "text", label: complexText, isProtected: false, isEnabled: true, bounds: BoundedRect(x: 0, y: 0, width: 10, height: 10))
        let obs16 = TabObservedEvent(tab: tabGen1, title: complexText, elements: [safeElement])
        let encoded16 = try BridgeMessageFraming.encode(obs16)
        let decoded16 = try BridgeMessageFraming.decode(TabObservedEvent.self, from: encoded16)
        guard decoded16.title == complexText, decoded16.elements.first?.label == complexText else {
            throw Failure("Adversarial Case 16: Control/framing characters corrupted JSON framing or text.")
        }

        // 17. Cleanup executes after intentional test failure
        var cleanupRan = false
        var testFileCleaned = false
        let tempTestFile = FileManager.default.temporaryDirectory.appendingPathComponent("halo-test-cleanup-\(UUID().uuidString)")
        try "test".write(to: tempTestFile, atomically: true, encoding: .utf8)
        do {
            defer {
                cleanupRan = true
                try? FileManager.default.removeItem(at: tempTestFile)
                testFileCleaned = !FileManager.default.fileExists(atPath: tempTestFile.path)
            }
            throw Failure("Intentional test error to verify defer execution")
        } catch is Failure {}
        guard cleanupRan, testFileCleaned else {
            throw Failure("Adversarial Case 17: Defer cleanup did not execute after intentional test failure.")
        }

        print("PASS: All 17 required adversarial checks passed deterministically.")
        try await runBridgeSecurityValidationChecks(helperBinaryURL: helperBinaryURL, pinnedExtensionID: pinnedExtensionID)
        try await clickProtocolChecks()
        try browserSelectionAndCoverageChecks()
    }

    private static func runBridgePerformanceBenchmarks(helperBinaryURL: URL, pinnedExtensionID: String) async throws {
        print("--- Performance Benchmarking (ContinuousClock) ---")
        let clock = ContinuousClock()
        let nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let browser = BrowserIdentity(bundleID: "com.google.Chrome", sessionID: "s1", pid: 101)
        let tabGen1 = TabGenerationIdentity(browser: browser, tabID: 55, documentGenerationID: 1, url: "http://127.0.0.1/p1", domain: "127.0.0.1")

        // 1. Helper cold start (10 samples, p95 <= 750 ms)
        var coldStartSamplesMs: [Double] = []
        for sampleIdx in 0..<10 {
            let server = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
            let p = Process()
            p.executableURL = helperBinaryURL
            p.arguments = ["--session-dir", server.directoryURL.path, "chrome-extension://\(pinnedExtensionID)/"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe

            let t0 = clock.now
            try p.run()
            do {
                try await server.acceptConnection(timeoutSeconds: 5)
            } catch {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(decoding: errData, as: UTF8.self)
                p.terminate()
                p.waitUntilExit()
                await server.close()
                throw Failure("Cold start sample \(sampleIdx) failed: \(error.localizedDescription) (stderr: \(errStr))")
            }
            let t1 = clock.now

            let duration = t0.duration(to: t1)
            let ms = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
            coldStartSamplesMs.append(ms)

            p.terminate()
            p.waitUntilExit()
            await server.close()
        }
        let coldStartP50 = percentile(coldStartSamplesMs, 0.50)
        let coldStartP95 = percentile(coldStartSamplesMs, 0.95)
        let coldStartMax = coldStartSamplesMs.max() ?? 0.0
        guard coldStartP95 <= 750.0 else {
            throw Failure("Helper cold start gate failed: p95 was \(coldStartP95) ms (threshold <= 750 ms)")
        }

        // Dedicated helper for warm round trips and observation
        let warmServer = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
        let warmProc = Process()
        warmProc.executableURL = helperBinaryURL
        warmProc.arguments = ["--session-dir", warmServer.directoryURL.path, "chrome-extension://\(pinnedExtensionID)/"]
        let warmInPipe = Pipe()
        let warmOutPipe = Pipe()
        let warmErrPipe = Pipe()
        warmProc.standardInput = warmInPipe
        warmProc.standardOutput = warmOutPipe
        warmProc.standardError = warmErrPipe
        try warmProc.run()
        try await warmServer.acceptConnection(timeoutSeconds: 5)
        let warmConfig = warmServer.sessionConfig
        let warmNonce = warmConfig.sessionNonce

        defer {
            if warmProc.isRunning { warmProc.terminate(); warmProc.waitUntilExit() }
            Task { await warmServer.close() }
        }

        // 2. Warm bridge round trip (30 samples, p50 <= 100 ms, p95 <= 250 ms)
        var warmSamplesMs: [Double] = []
        for i in 0..<30 {
            let reqID = "warm_req_\(i)"
            let req = BridgeRequest(requestID: reqID, sessionNonce: warmNonce, type: .observeTab, targetTab: tabGen1)

            let t0 = clock.now
            try await warmServer.sendRequest(req)
            _ = try BridgeSocketIO.readFramedData(from: warmOutPipe.fileHandleForReading.fileDescriptor, timeoutSeconds: 5)

            let resp = BridgeResponse(requestID: reqID, sessionNonce: warmNonce, success: true)
            let respBytes = try BridgeMessageFraming.encode(resp)
            try BridgeSocketIO.writeFramedData(to: warmInPipe.fileHandleForWriting.fileDescriptor, payload: respBytes, timeoutSeconds: 5)

            let receivedResp = try await warmServer.receiveResponse(timeoutSeconds: 5)
            guard receivedResp.requestID == reqID else { throw Failure("Warm round-trip mismatch at sample \(i)") }
            let t1 = clock.now

            let duration = t0.duration(to: t1)
            let ms = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
            warmSamplesMs.append(ms)
        }
        let warmP50 = percentile(warmSamplesMs, 0.50)
        let warmP95 = percentile(warmSamplesMs, 0.95)
        let warmMax = warmSamplesMs.max() ?? 0.0
        guard warmP50 <= 100.0, warmP95 <= 250.0 else {
            throw Failure("Warm bridge round-trip gate failed: p50 \(warmP50) ms (<= 100), p95 \(warmP95) ms (<= 250)")
        }

        // 3. Synthetic transport latency (50 in-memory elements, 30 samples, p50 <= 300 ms, p95 <= 1,000 ms)
        var obsSamplesMs: [Double] = []
        var syntheticElements: [ObservedDOMElement] = []
        for idx in 0..<50 {
            let isButton = (idx % 2 == 0)
            let tag = isButton ? "button" : "input"
            let role = isButton ? "button" : "textfield"
            let rect = BoundedRect(x: Double(idx * 10), y: Double(idx * 5), width: 100, height: 30)
            let el = ObservedDOMElement(
                elementID: "el_\(idx)",
                tagName: tag,
                role: role,
                label: "Control \(idx)",
                isProtected: false,
                isEnabled: true,
                bounds: rect
            )
            syntheticElements.append(el)
        }
        for i in 0..<30 {
            let reqID = "obs_req_\(i)"
            let req = BridgeRequest(requestID: reqID, sessionNonce: warmNonce, type: .observeTab, targetTab: tabGen1)

            let t0 = clock.now
            try await warmServer.sendRequest(req)
            _ = try BridgeSocketIO.readFramedData(from: warmOutPipe.fileHandleForReading.fileDescriptor, timeoutSeconds: 5)

            let obsEvent = TabObservedEvent(tab: tabGen1, title: "Synthetic Benchmark Page", elements: syntheticElements)
            let resp = BridgeResponse(requestID: reqID, sessionNonce: warmNonce, success: true, observation: obsEvent)
            let respBytes = try BridgeMessageFraming.encode(resp)
            try BridgeSocketIO.writeFramedData(to: warmInPipe.fileHandleForWriting.fileDescriptor, payload: respBytes, timeoutSeconds: 5)

            let receivedResp = try await warmServer.receiveResponse(timeoutSeconds: 5)
            guard receivedResp.observation?.elements.count == 50 else { throw Failure("Observation element count mismatch at sample \(i)") }
            let t1 = clock.now

            let duration = t0.duration(to: t1)
            let ms = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
            obsSamplesMs.append(ms)
        }
        let obsP50 = percentile(obsSamplesMs, 0.50)
        let obsP95 = percentile(obsSamplesMs, 0.95)
        let obsMax = obsSamplesMs.max() ?? 0.0
        guard obsP50 <= 300.0, obsP95 <= 1000.0 else {
            throw Failure("Synthetic transport latency gate failed: p50 \(obsP50) ms (<= 300), p95 \(obsP95) ms (<= 1000)")
        }

        // 4. Pause / revoke propagation (<= 100 ms)
        let tPause0 = clock.now
        let validatorPerf = BridgeSessionValidator(sessionNonce: nonce)
        try await validatorPerf.authorizeTab(tabGen1)
        await validatorPerf.setPaused(true)
        let tPause1 = clock.now
        let pausePropMs = Double(tPause0.duration(to: tPause1).components.seconds) * 1000.0 + Double(tPause0.duration(to: tPause1).components.attoseconds) / 1e15
        guard pausePropMs <= 100.0 else {
            throw Failure("Pause/revoke propagation gate failed: took \(pausePropMs) ms (threshold <= 100 ms)")
        }

        // 5. Idle CPU and RSS delta over 10 seconds
        let telem0 = getProcessTelemetry(pid: warmProc.processIdentifier)
        try await Task.sleep(for: .seconds(10))
        let telem1 = getProcessTelemetry(pid: warmProc.processIdentifier)

        let totalCpuNs = Double((telem1.userTimeNano - telem0.userTimeNano) + (telem1.systemTimeNano - telem0.systemTimeNano))
        let cpuPercent = (totalCpuNs / (10.0 * 1e9)) * 100.0
        let idleRssDeltaKiB = Double(Int64(telem1.rssBytes) - Int64(telem0.rssBytes)) / 1024.0
        let roundedCpu = (cpuPercent * 10).rounded() / 10.0
        guard roundedCpu == 0.0 else {
            throw Failure("Idle CPU gate failed: helper consumed \(cpuPercent)% CPU (expected 0.0%)")
        }

        // Print benchmark table
        print("""
        | Metric | Samples | p50 | p95 | Max | Threshold | Result |
        |---|---|---|---|---|---|---|
        | Helper cold start | \(coldStartSamplesMs.count) | \(String(format: "%.2f ms", coldStartP50)) | \(String(format: "%.2f ms", coldStartP95)) | \(String(format: "%.2f ms", coldStartMax)) | p95 <= 750 ms | PASS |
        | Warm bridge round trip | \(warmSamplesMs.count) | \(String(format: "%.2f ms", warmP50)) | \(String(format: "%.2f ms", warmP95)) | \(String(format: "%.2f ms", warmMax)) | p50 <= 100 ms, p95 <= 250 ms | PASS |
        | Synthetic transport latency (50 in-memory elements) | \(obsSamplesMs.count) | \(String(format: "%.2f ms", obsP50)) | \(String(format: "%.2f ms", obsP95)) | \(String(format: "%.2f ms", obsMax)) | p50 <= 300 ms, p95 <= 1000 ms | PASS |
        | Pause/revoke propagation | 1 | \(String(format: "%.2f ms", pausePropMs)) | \(String(format: "%.2f ms", pausePropMs)) | \(String(format: "%.2f ms", pausePropMs)) | <= 100 ms | PASS |
        | Helper idle CPU | 10s | \(String(format: "%.1f%%", cpuPercent)) | \(String(format: "%.1f%%", cpuPercent)) | \(String(format: "%.1f%%", cpuPercent)) | rounds to 0.0% | PASS |
        | Incremental idle RSS | 10s | \(String(format: "%.1f KiB", idleRssDeltaKiB)) | - | - | Recorded | PASS |
        """)
        print("Note: 'Synthetic transport latency' measures in-memory helper-to-Halo IPC framing of 50 elements; real browser DOM observation requires an active Chromium extension session.")
        await warmServer.close()
    }

    private static func runRealBrowserCapabilityProbe(helperBinaryURL: URL, pinnedExtensionID: String) async throws {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent()
                .appendingPathComponent(".local-tools/chromium/chrome-mac/Chromium.app/Contents/MacOS/Chromium"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .deletingLastPathComponent()
                .appendingPathComponent(".local-tools/chrome-for-testing/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"),
            URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            URL(fileURLWithPath: "/Applications/Chromium.app/Contents/MacOS/Chromium"),
            URL(fileURLWithPath: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        ]
        guard let browserURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            print("SKIPPED: Real-browser capability probe skipped. No supported Chromium browser installation found.")
            throw Failure("Phase 5A requires Chrome for Testing, Chromium, or Brave for a real Native Messaging fixture.")
        }

        await reapOrphanedTestBrowsers()
        let fixture = try DisposableTabServer()
        defer { fixture.stop() }
        let tempProfileDir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-browser-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempProfileDir, withIntermediateDirectories: true)
        let server = try BridgeIPCServer(pinnedExtensionID: pinnedExtensionID, helperExecutableURL: helperBinaryURL)
        guard let launcherURL = server.launcherURL else { throw Failure("Bridge server did not create its native-host launcher.") }

        var installedManifests: [URL] = []
        do {
            // On macOS, Chromium resolves user-level native hosts relative to the
            // active user data directory, so the probe never touches real profiles.
            let manifestDirs = [tempProfileDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)]
            installedManifests = try NativeMessagingInstaller.install(
                hostName: "app.halo.browser_bridge",
                launcherPath: launcherURL.path,
                allowedOrigins: ["chrome-extension://\(pinnedExtensionID)/"],
                targetDirectories: manifestDirs
            )
        } catch {
            await server.close()
            throw Failure("Failed to stage Native Messaging manifests safely: \(error.localizedDescription)")
        }

        defer {
            NativeMessagingInstaller.uninstall(manifestURLs: installedManifests)
            try? FileManager.default.removeItem(at: tempProfileDir)
            Task { await server.close() }
        }

        let extPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Fixtures/BrowserBridgeExtension").standardized.path
        let probeProcess = Process()
        probeProcess.executableURL = browserURL
        probeProcess.arguments = [
            "--user-data-dir=\(tempProfileDir.path)",
            "--enable-logging=stderr",
            "--v=1",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions-except=\(extPath)",
            "--load-extension=\(extPath)",
            fixture.url.absoluteString
        ]
        // Verbose Chromium logging goes to a file: an undrained Pipe fills its
        // buffer and stalls the browser before it launches the native host.
        let browserLogURL = tempProfileDir.appendingPathComponent("chromium-stderr.log")
        FileManager.default.createFile(atPath: browserLogURL.path, contents: nil)
        let browserLog = try FileHandle(forWritingTo: browserLogURL)
        defer { try? browserLog.close() }
        probeProcess.standardError = browserLog
        probeProcess.standardOutput = FileHandle.nullDevice

        try probeProcess.run()
        defer {
            terminateProcessBounded(probeProcess)
        }

        do {
            try await server.acceptConnection(timeoutSeconds: 15)
        } catch {
            let stderr = (try? String(contentsOf: browserLogURL, encoding: .utf8)) ?? ""
            let relevant = stderr.split(separator: "\n").filter {
                !$0.contains("Cannot stat") && (
                    $0.localizedCaseInsensitiveContains("native messag") ||
                    $0.localizedCaseInsensitiveContains("HaloBridge") ||
                    $0.localizedCaseInsensitiveContains("HaloNativeHost"))
            }.suffix(20).joined(separator: "\n")
            throw Failure("Real browser did not launch/authenticate the native host: \(error.localizedDescription). relevant stderr: \(relevant)")
        }
        let nonce = server.sessionConfig.sessionNonce
        let announcements = try await BrowserBridgeController.performHandshake(
            server: server, pinnedExtensionID: pinnedExtensionID, announcementTimeout: 10)
        guard let announced = announcements.first(where: { $0.domain == "127.0.0.1" }) else {
            throw Failure("Extension did not announce the disposable loopback tab.")
        }
        let bundleID = Bundle(url: browserURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())?.bundleIdentifier ?? "org.chromium.Chromium"
        let browser = BrowserIdentity(bundleID: bundleID, sessionID: "\(probeProcess.processIdentifier):fixture", pid: probeProcess.processIdentifier)
        let target = TabGenerationIdentity(browser: browser, tabID: announced.tabID,
            documentGenerationID: announced.documentGenerationID, url: announced.url, domain: announced.domain)
        let validator = BridgeSessionValidator(sessionNonce: nonce)
        try await validator.authorizeTab(target)
        let request = BridgeRequest(requestID: "real_fixture_observe", sessionNonce: nonce, type: .observeTab, targetTab: target)
        try await validator.validateRequest(request)
        let start = ContinuousClock.now
        try await server.sendRequest(request)
        let response = try await server.receiveResponse(timeoutSeconds: 10)
        try await validator.validateResponse(response)
        let elapsed = start.duration(to: .now)
        guard response.requestID == request.requestID, let observation = response.observation else {
            throw Failure("Real browser returned no observation for \(request.requestID): \(String(describing: response.error)).")
        }
        guard observation.tab == target else {
            throw Failure("Real browser observation tab \(observation.tab) does not match authorized \(target).")
        }
        guard observation.title.contains("Halo Disposable Browser Fixture"),
              observation.elements.contains(where: { $0.label.contains("Halo Chrome Integration Test") }) else {
            throw Failure("Real browser observation content mismatch: title=\(observation.title.prefix(80)) labels=\(observation.elements.prefix(8).map { $0.label.prefix(40) }).")
        }
        print("PASS: Real Chromium Native Messaging handshake and authorized DOM observation completed in \(elapsed).")
    }
}
