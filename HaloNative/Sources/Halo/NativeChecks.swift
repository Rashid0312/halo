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
        let focusRes = try await tools.execute(name: "focus_app", arguments: #"{"app_id":"\#(hostAppID)"}"#)
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
        let layoutRes = try await tools.execute(name: "window_layout", arguments: #"{"app_id":"\#(hostAppID)","position":"left"}"#)
        guard let layoutObj = try? JSONSerialization.jsonObject(with: Data(layoutRes.utf8)) as? [String: Any],
              layoutObj["ok"] as? Bool == true else {
            throw Failure("window_layout failed: \(layoutRes)")
        }

        print("PASS: \(expectedDriver) driver Safe Mac actions: focus, stale ID rejection, approval preview/denial/cancellation, control click, typing, shortcut, scroll, menu selection, dialog operation, and window layout verified with post-action observation")
    }

    private static func waitForApproval(_ tools: MacTools, attempts: Int = 300, step: String = "") async throws -> MacTools.Approval {
        for _ in 0..<attempts {
            if let approval = tools.approval { return approval }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure("Approval did not appear for step '\(step)'")
    }
}
