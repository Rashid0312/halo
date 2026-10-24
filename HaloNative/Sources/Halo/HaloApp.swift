@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import HaloCore

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(HaloDelegate.self) private var delegate
    var body: some Scene {
        Settings { MercySettings(voice: delegate.voice, wake: delegate.wake, setHandsFree: delegate.setHandsFree, catalog: delegate.catalog, macTools: delegate.macTools, presentation: delegate.presentation, auth: delegate.auth, browserBridge: delegate.browserBridge, connectorAccounts: delegate.connectorAccounts, deepSeekKey: delegate.deepSeekKey, runSetup: delegate.showFirstRun) }
            .defaultSize(width: 960, height: 680)
            .windowResizability(.contentMinSize)
    }
}

@MainActor
final class HaloDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel!
    let presentation = PanelPresentation()
    private var panelTransition = UUID()
    private var isRetracting = false
    private var anchorScreen: NSScreen?
    private var retractTask: Task<Void, Never>?
    private var clickAwayMonitor: Any?
    private var displayObserver: NSObjectProtocol?
    private var retractWhenIdle = false
    private var audioObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var audioRecovery: Task<Void, Never>?
    private var sleeping = false
    private var conversation = Conversation()
    let voice = VoiceController()
    let wake = WakeController()
    let catalog = AppCatalog()
    let auth = ChatGPTAuth()
    let deepSeekKey = DeepSeekKey()
    lazy var macTools = MacTools(catalog: catalog)
    lazy var connectorAccounts = ConnectorAccounts(manager: macTools.connectors)
    let browserBridge = BrowserBridgeController()
    private let firstRun = FirstRunWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--ui-test-host") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                UIAutomation.launchTestHost()
            }
            return
        }
        if CommandLine.arguments.contains("--check-chatgpt-auth") {
            Task {
                do { try await NativeChecks.chatGPT(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-ui-interaction") {
            Task {
                do { try await UIAutomation.checkInteraction(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-peekaboo-capture") {
            Task {
                do { try await NativeChecks.peekabooCapture(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-peekaboo-listing") {
            Task {
                do { try await NativeChecks.peekabooListing(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-safe-actions") {
            Task {
                do { try await NativeChecks.safeMacActions(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--time-browser-tools") {
            Task {
                do { try await NativeChecks.timeBrowserTools(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-real-chrome") {
            Task {
                do { try await NativeChecks.realChromeCheck(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-mercy-screens"), index + 1 < CommandLine.arguments.count {
            do { try NativeChecks.renderMercyScreens(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), delegate: self); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--check-browser-settle") {
            Task {
                do { try await NativeChecks.browserSettleCheck(helperBinaryURL: NativeChecks.locateHelperBinary()); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-browser-bridge-live") {
            Task {
                do { try await NativeChecks.runRealBrowserLifecycleSuite(helperBinaryURL: NativeChecks.locateHelperBinary()); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-browser-tabs") || CommandLine.arguments.contains("--check-browser-bridge") {
            Task {
                do { try await NativeChecks.browserTabIntegration(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-web-research") {
            Task {
                do { try await NativeChecks.webResearch(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-app-lifecycle") {
            Task {
                do { try await NativeChecks.appLifecycle(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-commands") {
            Task {
                do { try await NativeChecks.commands(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-ui-controls") {
            Task {
                do { try await NativeChecks.ui(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-ui-inspect"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    let arguments = try JSONSerialization.data(withJSONObject: [
                        "app_id": CommandLine.arguments[index + 1],
                    ])
                    let snapshot = try await macTools.execute(
                        name: "inspect_ui",
                        arguments: String(decoding: arguments, as: UTF8.self)
                    )
                    let object = try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any]
                    let count = (object?["elements"] as? [[String: Any]])?.count ?? 0
                    guard count > 1 else { throw ProviderError.invalidStream }
                    let driver = object?["driver"] as? String ?? "legacy"
                    print("PASS: \(driver) Accessibility inspection returned \(count) observed controls; UI contents not printed")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-connect-card"), index + 1 < CommandLine.arguments.count {
            do { try ConnectorChecks.renderCards(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--check-oauth-callback") {
            Task {
                do { try await ConnectorChecks.callback(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-connectors-offline") {
            Task {
                do { try await ConnectorChecks.offline(); ConnectorProcesses.terminateAll(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); ConnectorProcesses.terminateAll(); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--connect-connector"), index + 1 < CommandLine.arguments.count {
            // The same sign-in as Settings → Connect, for checks; then a read-only call.
            let id = CommandLine.arguments[index + 1], arguments = CommandLine.arguments
            func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
            Task {
                do {
                    guard let spec = ConnectorSpec.spec(id) else { throw NativeChecks.Failure("Unknown connector \(id)") }
                    print("Opening \(spec.name) sign-in in your browser…")
                    try ConnectorTokenStore.save(id, try await ConnectorOAuth.signIn(spec))
                    print("PASS: \(spec.name) OAuth sign-in completed and saved to Credentials")
                    try await ConnectorChecks.live(id, tool: value("--tool"), arguments: value("--arguments") ?? "{}")
                    ConnectorProcesses.terminateAll(); exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); ConnectorProcesses.terminateAll(); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-connector"), index + 1 < CommandLine.arguments.count {
            let arguments = CommandLine.arguments
            func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
            Task {
                do { try await ConnectorChecks.live(arguments[index + 1], tool: value("--tool"), arguments: value("--arguments") ?? "{}"); ConnectorProcesses.terminateAll(); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); ConnectorProcesses.terminateAll(); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-native-files") {
            Task {
                do { try await NativeChecks.files(macTools); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-app-voice-file"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    await catalog.refresh()
                    voice.contextualWords = AppResolver.speechVocabulary(apps: catalog.apps)
                    let text = try await WakeController.checkRequestFile(CommandLine.arguments[index + 1], voice: voice)
                    guard let target = AppResolver.launchTarget(in: text), case .match(let app) = AppResolver.resolve(target, apps: catalog.apps),
                          app.name.localizedCaseInsensitiveContains("stremio") else {
                        print("FAIL: synthetic app phrase transcribed as: \(text)"); exit(1)
                    }
                    print("PASS: local wake, app vocabulary, transcription, and spoken app resolution; no app launched or cloud call")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-app-catalog") {
            Task {
                await catalog.refresh()
                let result = AppResolver.resolve("streamio", apps: catalog.apps)
                guard case .match(let app) = result, app.name.localizedCaseInsensitiveContains("stremio"),
                      FileManager.default.fileExists(atPath: app.path),
                      AppResolver.speechVocabulary(apps: catalog.apps).contains(where: { $0.localizedCaseInsensitiveContains("stremio") }) else {
                    print("FAIL: installed Stremio or its spoken alias was not found"); exit(1)
                }
                print("PASS: \(catalog.apps.count) real app bundles indexed; streamio resolves to installed \(app.name); speech vocabulary includes it")
                exit(0)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-open-app"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    await catalog.refresh()
                    guard let response = try await catalog.handle("Open " + CommandLine.arguments[index + 1]), response.hasPrefix("Opened ") else {
                        print("FAIL: no exact installed app match"); exit(1)
                    }
                    print("PASS: native NSWorkspace app launch completed")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-wake-microphone") {
            Task {
                wake.setEnabled(true, voice: voice, conversation: conversation)
                for _ in 0..<200 {
                    if wake.running { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if !wake.enabled { print("FAIL: \(wake.status)"); exit(1) }
                }
                guard wake.running else { wake.stop(); print("FAIL: wake microphone setup timed out"); exit(1) }
                try? await Task.sleep(for: .seconds(3))
                wake.stop(); voice.cancel()
                print("PASS: native wake microphone capture runs and stops; no cloud call")
                exit(0)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-handsfree-file"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    let result = try await WakeController.checkRequestFile(CommandLine.arguments[index + 1], voice: voice)
                    guard !result.lowercased().contains("mercy"), !result.isEmpty else { throw WakeFailure.models }
                    print("PASS: wake → buffered speech → silence endpoint → request without wake phrase; no cloud call")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-wake-file"), index + 1 < CommandLine.arguments.count {
            do {
                let hit = try WakeController.checkFile(CommandLine.arguments[index + 1])
                let expected = !CommandLine.arguments.contains("--expect-no-wake")
                print(hit == expected ? "PASS: local keyword detection matched expectation" : "FAIL: local keyword detection differed from expectation")
                exit(hit == expected ? 0 : 1)
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        if CommandLine.arguments.contains("--check-audio-callback") {
            Task {
                do {
                    try await VoiceController.checkAudioCallback()
                    print("PASS: microphone callback executes off the main actor and converts audio")
                    exit(0)
                } catch {
                    print("FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--check-microphone") {
            Task {
                voice.startListening()
                for _ in 0..<300 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if voice.phase == .listening { break }
                    if voice.phase == .idle { print("FAIL: \(voice.notice)"); exit(1) }
                }
                guard voice.phase == .listening else { voice.cancel(); print("FAIL: microphone setup timed out"); exit(1) }
                try? await Task.sleep(for: .seconds(3))
                voice.finishListening()
                for _ in 0..<150 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if voice.phase == .idle { break }
                }
                let completed = voice.phase == .idle && !voice.notice.contains("failed") && !voice.notice.contains("timed out")
                voice.cancel()
                print(completed ? "PASS: live microphone capture and finalization; transcript not logged or sent" : "FAIL: live microphone did not finalize")
                exit(completed ? 0 : 1)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--check-speech-file"), index + 1 < CommandLine.arguments.count {
            Task {
                do {
                    let text = try await VoiceController.checkSpeechFile(CommandLine.arguments[index + 1])
                    guard text.lowercased().contains("mercy") else {
                        print("FAIL: expected wake name absent from synthetic speech transcription")
                        exit(1)
                    }
                    print("PASS: native audio conversion and on-device speech finalization (\(text.count) characters)")
                    exit(0)
                } catch {
                    print("FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        let key = deepSeekKey.value
        voice.configureDeepgram(key: Credentials.existingDeepgramKey())
        conversation = Conversation(provider: MacReplyProvider(
            fallback: BrainRouter(auth: auth, tools: macTools, deepSeekKey: deepSeekKey),
            researchFallback: BrainRouter(auth: auth, tools: nil, deepSeekKey: deepSeekKey),
            catalog: catalog
        ), providerName: auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek")
        auth.onProviderChange = { [weak self] in
            guard let self else { return }
            self.conversation.changeProviderName(self.auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek")
            self.macTools.modelProviderName = self.auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek"
        }
        macTools.modelProviderName = auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek"
        if CommandLine.arguments.contains("--check-screen") {
            Task {
                do { try await NativeChecks.screen(key: key); exit(0) }
                catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-model-tools") {
            Task {
                do {
                    var called = false
                    macTools.onExecution = { name in if name == "list_apps" { called = true } }
                    var count = 0
                    let provider = DeepSeekProvider(key: key, tools: macTools)
                    for try await delta in provider.reply(to: [Message(isUser: true, text: "Use list_apps to check if Stremio is installed, then answer with only yes or no.")]) { count += delta.count }
                    guard called && count > 0 else { throw ProviderError.invalidStream }
                    print("PASS: live model called native list_apps and completed its reply; key and app list not printed")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--check-web-answer") {
            Task {
                do {
                    var called: Set<String> = []
                    macTools.onExecution = { called.insert($0) }
                    var answer = ""
                    let provider = MacReplyProvider(fallback: DeepSeekProvider(key: key, tools: macTools), researchFallback: DeepSeekProvider(key: key), catalog: catalog)
                    let started = Date()
                    for try await delta in provider.reply(to: [Message(isUser: true, text: "Check whether a new Bleach: Thousand-Year Blood War anime episode is out. Research the current web now and answer directly with source links.")]) { answer += delta }
                    guard !answer.isEmpty, Date().timeIntervalSince(started) < 45,
                          !answer.lowercased().contains("can't read the page") else { throw ProviderError.invalidStream }
                    print("PASS: deterministic research plus one live answer completed in under 45 seconds; answer and credentials hidden; extra model tool calls: \(called.count)")
                    exit(0)
                } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
            }
            return
        }
        if CommandLine.arguments.contains("--time-provider") {
            Task {
                // Latency of the configured DeepSeek key, with and without Halo's
                // tool list. Prints timings and sizes only; key and replies hidden.
                let definitions = (try? await macTools.definitions()) ?? Data("[]".utf8)
                print("Tool definitions: \(definitions.count) bytes; system prompt: \(DeepSeekProvider.assistantInstructions.utf8.count) bytes")
                for (label, withTools) in [("no tools", false), ("Halo's full tool list", true)] {
                    for run in 1...3 {
                        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
                        request.httpMethod = "POST"
                        request.timeoutInterval = 90
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        var body: [String: Any] = ["model": "deepseek-flash", "stream": true, "max_tokens": 50, "thinking": ["type": "disabled"],
                                                   "messages": [["role": "system", "content": DeepSeekProvider.assistantInstructions],
                                                                ["role": "user", "content": "Reply with OK."]]]
                        if withTools, let rows = try? JSONSerialization.jsonObject(with: definitions) as? [[String: Any]] { body["tools"] = rows }
                        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                        let start = ContinuousClock.now
                        var firstByte: Duration?
                        do {
                            let (bytes, response) = try await URLSession.shared.bytes(for: request)
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            for try await line in bytes.lines where line.hasPrefix("data:") { if firstByte == nil { firstByte = start.duration(to: .now) } }
                            let total = start.duration(to: .now)
                            print("\(label) run \(run): HTTP \(status), first data \(firstByte.map { "\($0)" } ?? "none"), total \(total)")
                        } catch {
                            print("\(label) run \(run): failed after \(start.duration(to: .now)): \(error.localizedDescription)")
                        }
                    }
                }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--check-provider") {
            Task {
                do {
                    var count = 0
                    for try await delta in DeepSeekProvider(key: key).reply(to: [Message(isUser: true, text: "Reply with OK.")]) { count += delta.count }
                    guard count > 0 else { throw ProviderError.invalidStream }
                    print("PASS: native DeepSeek stream completed (\(count) characters); credential value hidden")
                    exit(0)
                } catch {
                    print("FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return
        }
        macTools.showApproval = { [weak self] in self?.showPanel(focusComposer: false) }
        macTools.onActivity = { [weak self] title in self?.conversation.reportActivity(title) }
        catalog.onRefresh = { [weak self] words in self?.voice.contextualWords = words }
        Task { await catalog.refresh() }
        // Fills the brain snapshot so the first request needn't wait on the main thread.
        if auth.provider == "chatgpt" { Task { try? await auth.loadModels() } }
        voice.onStart = { [weak self] in self?.conversation.stop() }
        voice.onTranscript = { [weak self] text in self?.conversation.send(text) }
        conversation.onReplyStart = { [weak self] in self?.voice.beginReply() }
        conversation.onReplyDelta = { [weak self] text in self?.voice.appendReply(text) }
        conversation.onReply = { [weak self] text in self?.voice.finishReply(text) }
        conversation.onStop = { [weak self] in self?.voice.stopSpeaking(); self?.macTools.cancelApproval() }
        NSApp.setActivationPolicy(.accessory)
        BrowserActivityTracker.shared.start()
        browserBridge.resumeIfEnabled()
        // Test-only: accept prompts posted by a local tester, through the same
        // path as typing in the panel. Off unless launched with this flag.
        if CommandLine.arguments.contains("--accept-test-prompts") {
            TimingLog.shared.startMainThreadMonitor()
            // Test-only: how to answer approvals ("approve", "deny", or "ask" for the normal prompt).
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.halo.native.dev.testApproval"),
                                                                object: nil, queue: .main) { [weak self] note in
                let answer = note.object as? String
                MainActor.assumeIsolated { self?.macTools.testApprovalAnswer = answer == "approve" ? true : answer == "deny" ? false : nil }
            }
            // Test-only: start a fresh conversation.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.halo.native.dev.testReset"),
                                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.conversation.stop(); self?.conversation.clear() }
            }
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("app.halo.native.dev.testPrompt"),
                                                                object: nil, queue: .main) { [weak self] note in
                guard let prompt = note.object as? String, !prompt.isEmpty else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.showPanel(focusComposer: false)
                    self.conversation.send(prompt)
                    // Test-only: block the main thread right after sending, to
                    // prove the request and browser tools never wait on it.
                    if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--simulate-main-stall=") }),
                       let seconds = Double(arg.dropFirst("--simulate-main-stall=".count)), seconds > 0 {
                        DispatchQueue.main.async {
                            TimingLog.shared.mark("simulated main stall start (\(seconds) s)")
                            Thread.sleep(forTimeInterval: seconds)
                            TimingLog.shared.mark("simulated main stall end")
                        }
                    }
                }
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Halo")
        item.button?.toolTip = "Mercy — open Halo"
        item.button?.setAccessibilityLabel("Halo")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        panel = HaloPanel(
            contentRect: NSRect(x: 0, y: 0, width: 190, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Halo"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Panel-state marks in timing.log, to correlate with main-thread freezes.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                TimingLog.shared.mark(self.panel.occlusionState.contains(.visible) ? "panel: visible" : "panel: occluded")
            }
        }
        // The window server's shadow follows the drawn rounded shape. A SwiftUI
        // shadow reached past the window's 8 pt margin and was cut off in a box.
        panel.hasShadow = PanelExperiment.on("shadow")
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSHostingView(rootView: ConversationView(
            conversation: conversation, voice: voice, wake: wake, setHandsFree: setHandsFree,
            catalog: catalog, macTools: macTools, presentation: presentation, auth: auth,
            expand: { [weak self] in self?.showPanel() },
            retract: { [weak self] in self?.collapsePanel() },
            activityChanged: { [weak self] in self?.panelActivityChanged() }
        ))
        content.sizingOptions = []
        panel.contentView = content
        presentation.onModeChange = { [weak self] in self?.panelModeChanged() }
        if presentation.keepInCorner { showCornerCapsule() }
        installPanelBehavior()
        wake.onWake = { [weak self] in self?.showPanel(focusComposer: false) }
        setHandsFree(UserDefaults.standard.object(forKey: "wakeEnabled") as? Bool ?? true)
        TraceRecorder.shared.isEnabled = UserDefaults.standard.bool(forKey: "recordTraces")
        // Test-only: record into a separate folder so test runs never mix with training data.
        if CommandLine.arguments.contains("--accept-test-prompts"),
           let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--trace-dir=") }) {
            TraceRecorder.shared.directory = URL(fileURLWithPath: String(arg.dropFirst("--trace-dir=".count)))
            TraceRecorder.shared.isEnabled = true
        }
        installAudioRecovery()
        if CommandLine.arguments.contains("--request-mac-controls") { macTools.ui.requestAccess() }
        // Test runs drive Halo by itself; setup would sit in their way.
        if !FirstRunWindow.isComplete, !CommandLine.arguments.contains("--accept-test-prompts") { showFirstRun() }
    }

    func showFirstRun() {
        firstRun.show(auth: auth, deepSeekKey: deepSeekKey, macTools: macTools, wake: wake, voice: voice,
                      setHandsFree: setHandsFree) { [weak self] in self?.showPanel() }
    }

    func setHandsFree(_ enabled: Bool) {
        audioRecovery?.cancel(); audioRecovery = nil
        wake.setEnabled(enabled, voice: voice, conversation: conversation)
    }

    private func installAudioRecovery() {
        audioObservers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            guard let object = notification.object else { return }
            let id = ObjectIdentifier(object as AnyObject)
            Task { @MainActor [weak self] in
                guard let self, self.voice.ownsAudioEngine(id) || self.wake.ownsAudioEngine(id) else { return }
                self.recoverAudio()
            }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleeping = true
                self.audioRecovery?.cancel(); self.audioRecovery = nil
                self.wake.stop(); self.voice.cancel()
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sleeping = false
                self?.recoverAudio()
            }
        })
    }

    private func recoverAudio() {
        audioRecovery?.cancel()
        wake.stop()
        voice.audioDeviceChanged()
        guard !sleeping else { return }
        audioRecovery = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, !Task.isCancelled, !self.sleeping else { return }
            let enabled = UserDefaults.standard.object(forKey: "wakeEnabled") as? Bool ?? true
            self.wake.setEnabled(enabled, voice: self.voice, conversation: self.conversation)
        }
    }

    @objc private func togglePanel() {
        if presentation.isExpanded && !isRetracting { collapsePanel() } else { showPanel() }
    }

    private func panelFrame(expanded: Bool) -> NSRect {
        let screen = anchorScreen ?? item?.button?.window?.screen ?? panel?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = expanded ? 360 : 190
        let preferredHeight: CGFloat = macTools.approval != nil ? 610 : conversation.messages.isEmpty ? 292 : 470
        let height = expanded ? min(preferredHeight, visible.height - 20) : 54
        return NSRect(x: visible.maxX - width - 2, y: visible.maxY - height - 2, width: width, height: height)
    }

    private func animatePanel(to frame: NSRect) {
        guard panel.frame != frame else { return }
        TimingLog.shared.mark("panel: resizing")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !PanelExperiment.on("resize") {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                // The shadow is traced from the content once; retrace it at the new size.
                MainActor.assumeIsolated { self?.panel.invalidateShadow() }
            }
        }
    }

    private func showPanel(focusComposer: Bool = true) {
        retractTask?.cancel()
        panelTransition = UUID()
        isRetracting = false
        retractWhenIdle = !focusComposer
        macTools.ui.rememberFrontmost()
        if focusComposer || anchorScreen == nil { anchorScreen = item?.button?.window?.screen ?? NSScreen.main }
        let wasVisible = panel.isVisible
        TimingLog.shared.mark(wasVisible ? "panel: shown" : "panel: sliding in")
        presentation.isExpanded = true
        let target = panelFrame(expanded: true)
        if !wasVisible {
            // Enter from the right edge, directly beneath the menu bar.
            panel.setFrame(target.offsetBy(dx: target.width + 16, dy: 0), display: false)
            panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        if focusComposer {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            presentation.focusRequest += 1
        }
    }

    private func showCornerCapsule() {
        panelTransition = UUID()
        isRetracting = false
        presentation.isExpanded = false
        panel.alphaValue = 1
        panel.setFrame(panelFrame(expanded: false), display: true)
        panel.orderFrontRegardless()
    }

    private func collapsePanel() {
        guard macTools.approval == nil else { return }
        retractTask?.cancel()
        panel.resignKey()
        if presentation.keepInCorner {
            panelTransition = UUID()
            isRetracting = false
            withAnimation(.easeInOut(duration: 0.24)) { presentation.isExpanded = false }
            animatePanel(to: panelFrame(expanded: false))
            return
        }
        guard panel.isVisible else { presentation.isExpanded = false; return }
        let transition = UUID()
        panelTransition = transition
        isRetracting = true
        TimingLog.shared.mark("panel: sliding out")
        let target = panel.frame.offsetBy(dx: panel.frame.width + 16, dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panelTransition == transition else { return }
                self.panel.orderOut(nil)
                TimingLog.shared.mark("panel: hidden")
                self.presentation.isExpanded = false
                self.isRetracting = false
                self.panel.alphaValue = 1
            }
        }
    }

    private func panelModeChanged() {
        retractTask?.cancel()
        if presentation.keepInCorner {
            if !presentation.isExpanded || !panel.isVisible || isRetracting { showCornerCapsule() }
        } else if !presentation.isExpanded {
            collapsePanel()
        } else {
            panelActivityChanged()
        }
    }

    private func panelActivityChanged() {
        guard panel != nil else { return }
        if presentation.isExpanded && !isRetracting { animatePanel(to: panelFrame(expanded: true)) }
        retractTask?.cancel()
        guard !presentation.keepInCorner, retractWhenIdle, presentation.isExpanded, !presentation.hovered, !presentation.hasDraft,
              !conversation.isResponding, !voice.isSpeaking, voice.phase == .idle,
              macTools.approval == nil, catalog.suggestions.isEmpty else { return }
        retractTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, !Task.isCancelled, !self.presentation.keepInCorner, !self.presentation.hovered, !self.presentation.hasDraft,
                  !self.conversation.isResponding, !self.voice.isSpeaking, self.voice.phase == .idle,
                  self.macTools.approval == nil else { return }
            self.collapsePanel()
        }
    }

    private func installPanelBehavior() {
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.presentation.isExpanded, !self.presentation.keepInCorner,
                      !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.collapsePanel()
            }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.anchorScreen = nil
                if self.panel.isVisible && !self.isRetracting {
                    self.animatePanel(to: self.panelFrame(expanded: self.presentation.isExpanded))
                }
            }
        }
    }

    /// halo://oauth/callback from the browser after a connector sign-in.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { OAuthCallbackRouter.shared.handle(url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioRecovery?.cancel()
        retractTask?.cancel()
        if let clickAwayMonitor { NSEvent.removeMonitor(clickAwayMonitor) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        wake.stop(); voice.cancel(); conversation.stop()
        browserBridge.shutdownForTermination()
        ConnectorProcesses.terminateAll()
    }
}
