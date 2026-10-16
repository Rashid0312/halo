import AppKit
import SwiftUI
import HaloCore

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(HaloDelegate.self) private var delegate
    var body: some Scene {
        Settings { HaloSettings(voice: delegate.voice, wake: delegate.wake, setHandsFree: delegate.setHandsFree, catalog: delegate.catalog, macTools: delegate.macTools) }
    }
}

@MainActor
final class HaloDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel!
    private var conversation = Conversation()
    let voice = VoiceController()
    let wake = WakeController()
    let catalog = AppCatalog()
    lazy var macTools = MacTools(catalog: catalog)

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        conversation = Conversation(provider: MacReplyProvider(fallback: DeepSeekProvider(key: key, tools: macTools), catalog: catalog), providerName: "DeepSeek")
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
        macTools.showApproval = { [weak self] in self?.showPanel() }
        catalog.onRefresh = { [weak self] words in self?.voice.contextualWords = words }
        Task { await catalog.refresh() }
        voice.onStart = { [weak self] in self?.conversation.stop() }
        voice.onTranscript = { [weak self] text in self?.conversation.send(text) }
        conversation.onReply = { [weak self] text in self?.voice.speak(text) }
        conversation.onStop = { [weak self] in self?.voice.stopSpeaking(); self?.macTools.cancelApproval() }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "Halo")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 550),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Halo"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ConversationView(conversation: conversation, voice: voice, wake: wake, setHandsFree: setHandsFree, catalog: catalog, macTools: macTools))
        showPanel()
        wake.onWake = { [weak self] in self?.showPanel() }
        setHandsFree(UserDefaults.standard.object(forKey: "wakeEnabled") as? Bool ?? true)
    }

    func setHandsFree(_ enabled: Bool) {
        wake.setEnabled(enabled, voice: voice, conversation: conversation)
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    private func showPanel() {
        let screen = item.button?.window?.screen ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 12))
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { wake.stop(); voice.cancel(); conversation.stop() }
}

struct ConversationView: View {
    @Bindable var conversation: Conversation
    @Bindable var voice: VoiceController
    @Bindable var wake: WakeController
    let setHandsFree: (Bool) -> Void
    @Bindable var catalog: AppCatalog
    @Bindable var macTools: MacTools
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Halo").font(.headline)
                    Text(voice.phase != .idle ? voice.notice : voice.isSpeaking ? "Speaking…" : conversation.status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Status: \(conversation.status)")
                }
                Spacer()
                Menu {
                    Button("Clear conversation", systemImage: "trash") { voice.cancel(); catalog.cancelSuggestion(); conversation.clear() }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Quit Halo", systemImage: "power") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Halo menu")
            }.padding(18)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Mercy / Hey Mercy", isOn: Binding(get: { wake.enabled }, set: { value in setHandsFree(value) }))
                    .toggleStyle(.switch)
                Text(wake.status).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Hello. I’m Halo.").font(.title2.weight(.semibold))
                                Text("Type a message or tap the microphone. Tap it again when you’re done speaking.")
                                    .foregroundStyle(.secondary)
                                Label("On-device speech · \(conversation.providerName) replies", systemImage: "waveform")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top, 38)
                        }
                        ForEach(conversation.messages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.isUser ? "YOU" : "HALO")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(message.text.isEmpty ? "…" : message.text)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(message.isUser ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(18)
                }
                .onChange(of: conversation.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            if let approval = macTools.approval {
                VStack(alignment: .leading, spacing: 8) {
                    Text(approval.title).font(.headline)
                    Text(approval.path).font(.caption).textSelection(.enabled)
                    ScrollView { Text(approval.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 160)
                    HStack {
                        Button("Cancel") { macTools.resolve(id: approval.id, allow: false) }
                        Spacer()
                        Button("Allow this change") { macTools.resolve(id: approval.id, allow: true) }.buttonStyle(.borderedProminent)
                    }
                }.padding(12)
                Divider()
            }
            if !macTools.activity.isEmpty { Text(macTools.activity).font(.caption).foregroundStyle(.secondary).padding(8) }
            if !catalog.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose the installed app").font(.caption).foregroundStyle(.secondary)
                    ForEach(catalog.suggestions) { app in
                        Button { voice.cancel(); catalog.choose(app, conversation: conversation) } label: {
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
                                Text(app.name)
                                Spacer()
                            }
                        }.buttonStyle(.bordered)
                    }
                    Button("Cancel") { catalog.cancelSuggestion(); voice.cancel() }
                }.padding(12)
                Divider()
            }
            if !voice.notice.isEmpty || !voice.transcript.isEmpty && voice.phase != .idle {
                VStack(alignment: .leading, spacing: 5) {
                    if !voice.notice.isEmpty { Text(voice.notice).font(.caption).foregroundStyle(.secondary) }
                    if !voice.transcript.isEmpty && voice.phase != .idle { Text(voice.transcript).font(.callout).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: {
                    if voice.phase == .idle { conversation.stop(); voice.stopSpeaking() }
                    wake.manual(voice: voice)
                }) {
                    Image(systemName: voice.phase == .listening ? "checkmark" : voice.phase == .idle ? "mic.fill" : "xmark")
                }
                .tint(voice.phase == .listening ? .red : .accentColor)
                .help(voice.phase == .listening ? "Finish speaking and send" : voice.phase == .idle ? "Talk to Halo" : "Cancel speech setup")
                .accessibilityLabel(voice.phase == .listening ? "Finish speaking and send" : "Microphone")
                TextField("Ask Halo…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($composerFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Message to Halo")
                if conversation.isResponding || voice.isSpeaking || voice.phase != .idle {
                    Button(action: { voice.cancel(); catalog.cancelSuggestion(); conversation.stop() }) { Image(systemName: "stop.fill") }
                        .help("Stop reply").accessibilityLabel("Stop reply")
                }
                Button(action: send) { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderedProminent).tint(.mint)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
            }.padding(16)
        }
        .background(.regularMaterial)
        .frame(minWidth: 400, minHeight: 550)
        .onAppear { composerFocused = true }
        .onExitCommand { voice.cancel(); catalog.cancelSuggestion(); conversation.stop() }
    }

    private func send() {
        voice.cancel()
        conversation.send(draft)
        draft = ""
        composerFocused = true
    }
}

struct HaloSettings: View {
    @Bindable var voice: VoiceController
    @Bindable var wake: WakeController
    let setHandsFree: (Bool) -> Void
    @Bindable var catalog: AppCatalog
    @Bindable var macTools: MacTools
    var body: some View {
        ScrollView { Form {
            LabeledContent("Provider", value: "DeepSeek · deepseek-flash")
            LabeledContent("Speech recognition", value: "Apple · On this Mac · English")
            Toggle("Speak replies", isOn: $voice.speakReplies)
            Toggle("Listen for Mercy or Hey Mercy", isOn: Binding(get: { wake.enabled }, set: { value in setHandsFree(value) }))
            Text(wake.status).font(.caption).foregroundStyle(.secondary)
            AppCatalogSettings(catalog: catalog)
            Section("Mac access") {
                Text("Mercy can open installed apps, inspect folders and text files, and prepare file changes. Allow access to protected folders in macOS settings when needed.").font(.caption).foregroundStyle(.secondary)
                Text("Add Halo.app to Full Disk Access to allow protected-file reads. macOS requires you to enable this yourself.").font(.caption).foregroundStyle(.secondary)
                Button("Show Halo in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                }
            }
            Text("Halo reuses your existing DeepSeek development key and stores its own copy in Keychain. Tap the microphone to talk, then tap again to send. Replies use the Mac’s system voice. When hands-free is on, wake detection stays on this Mac and your request sends automatically after a pause. Background audio is not sent to DeepSeek. Apps and files use native Mac tools; file changes require approval. ChatGPT sign-in and other Mac controls are still being added.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24) }.frame(width: 460, height: 650)
    }
}
