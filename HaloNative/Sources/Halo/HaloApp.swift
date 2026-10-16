@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import HaloCore

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(HaloDelegate.self) private var delegate
    var body: some Scene {
        Settings { HaloSettings(voice: delegate.voice, wake: delegate.wake, setHandsFree: delegate.setHandsFree, catalog: delegate.catalog, macTools: delegate.macTools, presentation: delegate.presentation, auth: delegate.auth) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--ui-test-host") {
            Task { try? await Task.sleep(for: .milliseconds(100)); UIAutomation.launchTestHost() }
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
                    let snapshot = try await macTools.ui.inspect(appID: CommandLine.arguments[index + 1])
                    let object = try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any]
                    let count = (object?["elements"] as? [[String: Any]])?.count ?? 0
                    guard count > 1 else { throw ProviderError.invalidStream }
                    print("PASS: native Accessibility inspection returned \(count) observed controls; UI contents not printed")
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
        conversation = Conversation(provider: MacReplyProvider(fallback: BrainRouter(auth: auth, tools: macTools, deepSeekKey: key), catalog: catalog), providerName: auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek")
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
        catalog.onRefresh = { [weak self] words in self?.voice.contextualWords = words }
        Task { await catalog.refresh() }
        voice.onStart = { [weak self] in self?.conversation.stop() }
        voice.onTranscript = { [weak self] text in self?.conversation.send(text) }
        conversation.onReply = { [weak self] text in self?.voice.speak(text) }
        conversation.onStop = { [weak self] in self?.voice.stopSpeaking(); self?.macTools.cancelApproval() }
        NSApp.setActivationPolicy(.accessory)
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
    var body: some View {
        ScrollView { Form {
            Section("Appearance") {
                Toggle("Keep in corner", isOn: $presentation.keepInCorner)
                Text("Off: open from the menu bar and retract to the side. On: stay visible in the corner; retract to a small capsule.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ChatGPTSettings(auth: auth)
            LabeledContent("Speech recognition", value: "Apple · On this Mac · English")
            Toggle("Speak replies", isOn: $voice.speakReplies)
            Toggle("Listen for Mercy or Hey Mercy", isOn: Binding(get: { wake.enabled }, set: { value in setHandsFree(value) }))
            Text(wake.status).font(.caption).foregroundStyle(.secondary)
            AppCatalogSettings(catalog: catalog)
            Section("Mac access") {
                Text("Mercy can open installed apps, inspect folders and text files, and prepare file changes. Allow access to protected folders in macOS settings when needed.").font(.caption).foregroundStyle(.secondary)
                Text("Add Halo.app to Full Disk Access to allow protected-file reads. macOS requires you to enable this yourself.").font(.caption).foregroundStyle(.secondary)
                Button("Show Halo in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Text(macTools.ui.trusted ? "Mac interface controls: enabled" : "Mac interface controls: permission needed").font(.caption)
                Button("Enable Mac controls…") { macTools.ui.requestAccess() }
                Text(macTools.screen.allowed ? "Screen capture: enabled" : "Screen capture: permission needed").font(.caption)
                Button("Check access") { macTools.ui.refreshAccess(); macTools.screen.refreshAccess() }
                Button("Open Screen Recording settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
                Text(Bundle.main.bundleURL.path).font(.caption2).textSelection(.enabled)
                if !macTools.lastFailure.isEmpty { Text(macTools.lastFailure).font(.caption).textSelection(.enabled) }
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
            }
            Text("Halo reuses your existing DeepSeek development key and stores its own copy in Keychain. Tap the microphone to talk, then tap again to send. Replies use the Mac’s system voice. When hands-free is on, wake detection stays on this Mac and your request sends automatically after a pause. Background audio is not sent to DeepSeek. Apps and files use native Mac tools; file changes require approval. Native UI inspection, button actions, text entry, shortcuts, and window layout are available with Accessibility permission. Generic UI actions show an approval preview. Screen understanding uses a screenshot preview before sharing with DeepSeek. Continue with ChatGPT in Brain settings to connect your ChatGPT account.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24) }.frame(width: 460, height: 650)
    }
}
