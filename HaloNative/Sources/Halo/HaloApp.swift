import AppKit
import SwiftUI
import HaloCore

@main
struct HaloApp: App {
    @NSApplicationDelegateAdaptor(HaloDelegate.self) private var delegate
    var body: some Scene {
        Settings { HaloSettings() }
    }
}

@MainActor
final class HaloDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: NSPanel!
    private var conversation = Conversation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = Credentials.existingDeepSeekKey()
        conversation = Conversation(provider: DeepSeekProvider(key: key), providerName: "DeepSeek")
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
        panel.contentView = NSHostingView(rootView: ConversationView(conversation: conversation))
        showPanel()
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

    func applicationWillTerminate(_ notification: Notification) { conversation.stop() }
}

struct ConversationView: View {
    @Bindable var conversation: Conversation
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Halo").font(.headline)
                    Text(conversation.status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Status: \(conversation.status)")
                }
                Spacer()
                Menu {
                    Button("Clear conversation", systemImage: "trash") { conversation.clear() }
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Quit Halo", systemImage: "power") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Halo menu")
            }.padding(18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if conversation.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Hello. I’m Halo.").font(.title2.weight(.semibold))
                                Text("Type a message to talk with Halo. Voice and Mac actions are coming next.")
                                    .foregroundStyle(.secondary)
                                Label("\(conversation.providerName) · microphone off", systemImage: "mic.slash")
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
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Halo…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($composerFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Message to Halo")
                if conversation.isResponding {
                    Button(action: { conversation.stop() }) { Image(systemName: "stop.fill") }
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
        .onExitCommand { conversation.stop() }
    }

    private func send() {
        conversation.send(draft)
        draft = ""
        composerFocused = true
    }
}

struct HaloSettings: View {
    var body: some View {
        Form {
            LabeledContent("Provider", value: "DeepSeek · deepseek-flash")
            LabeledContent("Microphone", value: "Off")
            Text("Halo reuses your existing DeepSeek development key and stores its own copy in Keychain. Voice, Mac actions, and ChatGPT sign-in are not connected yet.")
                .font(.callout).foregroundStyle(.secondary)
        }.padding(24).frame(width: 380)
    }
}
