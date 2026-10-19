@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import HaloCore

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(HaloDelegate.self) private var delegate
    var body: some Scene {
        Settings { HaloSettings(voice: delegate.voice, wake: delegate.wake, setHandsFree: delegate.setHandsFree, catalog: delegate.catalog, macTools: delegate.macTools, presentation: delegate.presentation, auth: delegate.auth, browserBridge: delegate.browserBridge) }
            .defaultSize(width: 820, height: 620)
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
    lazy var macTools = MacTools(catalog: catalog)
    let browserBridge = BrowserBridgeController()

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
        let key = Credentials.existingDeepSeekKey()
        voice.configureDeepgram(key: Credentials.existingDeepgramKey())
        conversation = Conversation(provider: MacReplyProvider(
            fallback: BrainRouter(auth: auth, tools: macTools, deepSeekKey: key),
            researchFallback: BrainRouter(auth: auth, tools: nil, deepSeekKey: key),
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
        voice.onStart = { [weak self] in self?.conversation.stop() }
        voice.onTranscript = { [weak self] text in self?.conversation.send(text) }
        conversation.onReplyStart = { [weak self] in self?.voice.beginReply() }
        conversation.onReplyDelta = { [weak self] text in self?.voice.appendReply(text) }
        conversation.onReply = { [weak self] text in self?.voice.finishReply(text) }
        conversation.onStop = { [weak self] in self?.voice.stopSpeaking(); self?.macTools.cancelApproval() }
        NSApp.setActivationPolicy(.accessory)
        browserBridge.resumeIfEnabled()
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
        panel.hasShadow = false
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
        installAudioRecovery()
        if CommandLine.arguments.contains("--request-mac-controls") { macTools.ui.requestAccess() }
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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                panel.animator().setFrame(frame, display: true)
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
        let target = panel.frame.offsetBy(dx: panel.frame.width + 16, dy: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.panelTransition == transition else { return }
                self.panel.orderOut(nil)
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
    }
}

struct HaloSettings: View {
    @Bindable var voice: VoiceController
    @Bindable var wake: WakeController
    let setHandsFree: (Bool) -> Void
    @Bindable var catalog: AppCatalog
    @Bindable var macTools: MacTools
    @Bindable var presentation: PanelPresentation
    @Bindable var auth: ChatGPTAuth
    @Bindable var browserBridge: BrowserBridgeController

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General"
        case voice = "Voice"
        case brain = "Brain"
        case apps = "Apps"
        case privacy = "Mac Access"

        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .voice: "waveform"
            case .brain: "sparkles"
            case .apps: "square.grid.2x2"
            case .privacy: "hand.raised"
            }
        }
    }

    @State private var page: Page = .general

    var body: some View {
        ZStack {
            FluidGradient(configuration: .init(
                colors: FluidGradientConfiguration.halo.colors,
                speed: 0.07,
                intensity: 0.55,
                opacity: 0.25
            ))
            Rectangle().fill(.regularMaterial.opacity(0.88))
            NavigationSplitView {
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.icon).tag(item)
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 185)
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HALO").font(.caption.weight(.semibold)).tracking(1.8)
                        Text("Private by design").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(page.rawValue).font(.system(size: 28, weight: .semibold, design: .rounded))
                        pageContent
                    }
                    .frame(maxWidth: 580, alignment: .leading)
                    .padding(30)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 620)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
            settingsCard("Halo bar", icon: "macwindow") {
                Toggle("Keep Halo in the corner", isOn: $presentation.keepInCorner)
                Text("When disabled, Halo lives in the menu bar and retracts to the side. When enabled, it remains as a compact capsule.")
                    .settingsNote()
            }
            settingsCard("Visuals", icon: "paintpalette") {
                LabeledContent("Fluid gradient", value: "Metal · 60 FPS")
                Text("The atmospheric background automatically becomes still when Reduce Motion is enabled in macOS.")
                    .settingsNote()
            }
        case .voice:
            settingsCard("Listening", icon: "mic") {
                Toggle("Listen for Mercy or Hey Mercy", isOn: Binding(get: { wake.enabled }, set: { setHandsFree($0) }))
                LabeledContent("Recognition", value: "Apple · On this Mac")
                Text(wake.status).settingsNote()
            }
            settingsCard("Spoken replies", icon: "speaker.wave.2") {
                Toggle("Speak replies", isOn: $voice.speakReplies)
                LabeledContent("Voice", value: "Deepgram Aura 2")
                Text("Microphone audio stays with Apple speech recognition. Only Halo's generated reply text is sent to Deepgram for speech.")
                    .settingsNote()
            }
        case .brain:
            settingsCard("Response provider", icon: "sparkles") {
                Form { ChatGPTSettings(auth: auth) }.formStyle(.grouped).scrollDisabled(true)
            }
        case .apps:
            settingsCard("Apps on this Mac", icon: "square.grid.2x2") {
                Form { AppCatalogSettings(catalog: catalog) }.formStyle(.grouped).scrollDisabled(true)
            }
        case .privacy:
            settingsCard("Action authorization", icon: "bolt.shield") {
                Text("Halo shows the exact command, script, file contents, screenshot, or interface action before carrying out a sensitive step. macOS permission prompts can still appear separately.")
                    .settingsNote()
            }
            settingsCard("Browser bridge", icon: "globe") {
                Toggle("Connect to the Halo browser extension (experimental)", isOn: $browserBridge.enabled)
                Text(browserBridge.status.summary).settingsNote()
                Text("Read-only. Halo registers a native host only while this is on, accepts only its pinned extension, and still asks before reading any tab.")
                    .settingsNote()
            }
            settingsCard("Permissions", icon: "lock.shield") {
                permissionRow("Mac interface controls", enabled: macTools.ui.trusted)
                permissionRow("Screen capture", enabled: macTools.screen.allowed)
                HStack {
                    Button("Enable Mac controls…") { macTools.ui.requestAccess() }
                    Button("Check access") { macTools.ui.refreshAccess(); macTools.screen.refreshAccess() }
                }
                HStack {
                    Button("Screen Recording…") { openPrivacy("Privacy_ScreenCapture") }
                    Button("Full Disk Access…") { openPrivacy("Privacy_AllFiles") }
                }
                if !macTools.lastFailure.isEmpty { Text(macTools.lastFailure).settingsNote().textSelection(.enabled) }
            }
            settingsCard("Halo application", icon: "app.badge") {
                Button("Show Halo in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Text(Bundle.main.bundleURL.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func settingsCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.headline)
            Divider().opacity(0.45)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    private func permissionRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(enabled ? "Enabled" : "Permission needed", systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(enabled ? .green : .secondary)
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

private extension View {
    func settingsNote() -> some View { font(.caption).foregroundStyle(.secondary) }
}
