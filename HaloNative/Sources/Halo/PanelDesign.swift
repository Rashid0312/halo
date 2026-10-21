import AppKit
import SwiftUI

/// Test-only switches for diagnosing panel rendering stalls:
/// launch with `--panel-off=spinner,material,shadow,gradient,resize`.
enum PanelExperiment {
    static let off: Set<String> = {
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--panel-off=") }) else { return [] }
        return Set(arg.dropFirst("--panel-off=".count).split(separator: ",").map(String.init))
    }()
    static func on(_ name: String) -> Bool { !off.contains(name) }
}
import Observation
import HaloCore

@MainActor
final class HaloPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
final class PanelPresentation {
    var isExpanded = false
    var hovered = false
    var hasDraft = false
    var focusRequest = 0
    var keepInCorner = UserDefaults.standard.bool(forKey: "keepInCorner") {
        didSet {
            guard keepInCorner != oldValue else { return }
            UserDefaults.standard.set(keepInCorner, forKey: "keepInCorner")
            onModeChange?()
        }
    }
    @ObservationIgnored var onModeChange: (() -> Void)?
}

struct ConversationView: View {
    @Bindable var conversation: Conversation
    @Bindable var voice: VoiceController
    @Bindable var wake: WakeController
    let setHandsFree: (Bool) -> Void
    @Bindable var catalog: AppCatalog
    @Bindable var macTools: MacTools
    @Bindable var presentation: PanelPresentation
    @Bindable var auth: ChatGPTAuth
    let expand: () -> Void
    let retract: () -> Void
    let activityChanged: () -> Void
    @State private var draft = ""
    @State private var showActivity = false
    @FocusState private var composerFocused: Bool

    private let ice = Color(red: 0.64, green: 0.86, blue: 0.91)
    private var busy: Bool { conversation.isResponding || voice.isSpeaking || voice.phase != .idle }
    private var status: String {
        if macTools.approval != nil { return "Your approval" }
        if voice.phase == .listening { return "Listening" }
        if voice.phase != .idle { return "Hearing you" }
        if voice.isSpeaking { return "Speaking" }
        if conversation.isResponding { return conversation.activity.isEmpty ? "Working" : conversation.activity.replacingOccurrences(of: "…", with: "") }
        return "Mercy"
    }
    private var activityKey: String {
        "\(conversation.isResponding)-\(voice.isSpeaking)-\(voice.phase)-\(macTools.approval?.id.uuidString ?? "")-\(conversation.messages.count)-\(catalog.suggestions.count)"
    }
    private var scrollKey: String {
        let lengthBucket = (conversation.messages.last?.text.count ?? 0) / 160
        return "\(conversation.messages.count)-\(lengthBucket)-\(conversation.isResponding)"
    }

    var body: some View {
        Group {
            if presentation.isExpanded { expanded }
            else { capsule }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .tint(ice)
        .onChange(of: activityKey) { _, _ in activityChanged() }
        .onChange(of: presentation.focusRequest) { _, _ in composerFocused = true }
        .onChange(of: draft) { _, text in presentation.hasDraft = !text.isEmpty; activityChanged() }
        .onChange(of: presentation.isExpanded) { _, value in if !value { composerFocused = false } }
        .onHover { value in presentation.hovered = value; activityChanged() }
        .onExitCommand {
            if macTools.approval == nil {
                if busy { voice.cancel(); catalog.cancelSuggestion(); conversation.stop() }
                retract()
            }
        }
    }

    private var mark: some View {
        // Still, not pulsing: a repeating symbol effect redraws every frame, and
        // each frame waited on the window server, freezing Halo for up to 57 s
        // while it answered on a Mac short on memory (2026-10-21).
        Image(systemName: busy ? "waveform" : "circle.hexagongrid.fill")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(ice)
            .frame(width: 22, height: 22)
    }

    private var capsule: some View {
        ZStack {
            if PanelExperiment.on("gradient") { FluidGradient(configuration: .bar) } else { Color(red: 0.42, green: 0.45, blue: 0.75) }
            if PanelExperiment.on("material") { Capsule().fill(.ultraThinMaterial.opacity(0.62)) } else { Capsule().fill(Color.black.opacity(0.3)) }
            Button(action: expand) {
                HStack(spacing: 10) {
                    mark
                    Text(status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Circle().fill(wake.enabled ? ice : Color.secondary.opacity(0.6)).frame(width: 4, height: 4)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 38)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: PanelExperiment.on("shadow") ? 12 : 0, y: 4)
        .accessibilityLabel("Open Halo")
        .help("Open Mercy")
    }

    private var expanded: some View {
        ZStack {
            if PanelExperiment.on("gradient") { FluidGradient(configuration: .halo) } else { Color(red: 0.42, green: 0.45, blue: 0.75) }
            if PanelExperiment.on("material") { Rectangle().fill(.ultraThinMaterial.opacity(0.70)) } else { Rectangle().fill(Color.black.opacity(0.3)) }
            VStack(spacing: 0) {
                header
                conversationBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let approval = macTools.approval { approvalCard(approval) }
                if !catalog.suggestions.isEmpty { appChoices }
                if !voice.notice.isEmpty || voice.phase != .idle && !voice.transcript.isEmpty { speechStatus }
                if conversation.isResponding || !conversation.activitySteps.isEmpty { activityCard }
                composer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(
            LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.2), radius: PanelExperiment.on("shadow") ? 20 : 0, y: 8)
        .transition(.opacity)
    }

    private var activityCard: some View {
        // Ticks only while a reply runs: each tick redraws the panel.
        TimelineView(.periodic(from: .now, by: conversation.isResponding ? 1 : 3600)) { context in
            VStack(alignment: .leading, spacing: 7) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { showActivity.toggle() } } label: {
                    HStack(spacing: 7) {
                        if conversation.isResponding && PanelExperiment.on("spinner") { ProgressView().controlSize(.mini) }
                        Text(conversation.activity.isEmpty ? conversation.status : conversation.activity)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        if let step = conversation.activitySteps.last {
                            Text(elapsed(step, at: context.date)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        Image(systemName: showActivity ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                }.buttonStyle(.plain)
                if showActivity {
                    ForEach(conversation.activitySteps) { step in
                        HStack(spacing: 7) {
                            Image(systemName: step.state == .active ? "circle.dotted" : step.state == .failed ? "xmark.circle" : "checkmark.circle.fill")
                                .foregroundStyle(step.state == .failed ? .red : step.state == .active ? ice : .secondary)
                            Text(step.title).lineLimit(2)
                            Spacer(minLength: 4)
                            Text(elapsed(step, at: context.date)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        }.font(.system(size: 10)).foregroundStyle(step.state == .active ? .primary : .secondary)
                    }
                    if conversation.isResponding {
                        HStack {
                            Button("Stop") { voice.cancel(); catalog.cancelSuggestion(); conversation.stop() }
                            if conversation.activity.contains("taking longer") {
                                Button("Retry") { voice.cancel(); conversation.retry() }
                            }
                            Spacer()
                        }.controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private func elapsed(_ step: ActivityStep, at now: Date) -> String {
        let seconds = max(0, Int((step.finishedAt ?? now).timeIntervalSince(step.startedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    private var header: some View {
        HStack(spacing: 9) {
            mark
            Text("MERCY").font(.system(size: 10, weight: .semibold)).tracking(2.1)
            Spacer()
            if busy { Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            Menu {
                Toggle("Listen for Mercy / Hey Mercy", isOn: Binding(get: { wake.enabled }, set: { value in setHandsFree(value) }))
                Toggle("Keep in corner", isOn: $presentation.keepInCorner)
                Toggle("Speak replies", isOn: $voice.speakReplies)
                Menu("Brain") {
                    Button("DeepSeek") { auth.provider = "deepseek" }
                    Button("ChatGPT") { auth.provider = "chatgpt" }.disabled(!auth.sharing)
                    SettingsLink { Text("Connect ChatGPT…") }
                }
                Divider()
                Button("Clear conversation", systemImage: "trash") { voice.cancel(); catalog.cancelSuggestion(); conversation.clear() }
                SettingsLink { Text("Settings…") }
                Divider()
                Button("Quit Halo") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Halo menu")
            Button { presentation.keepInCorner.toggle() } label: {
                Image(systemName: presentation.keepInCorner ? "pin.fill" : "pin")
                    .font(.system(size: 11)).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(presentation.keepInCorner ? ice : .secondary)
            .help(presentation.keepInCorner ? "Return to menu bar mode" : "Keep in corner")
            .accessibilityLabel("Keep in corner").accessibilityValue(presentation.keepInCorner ? "On" : "Off")
            Button(action: retract) { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(macTools.approval != nil)
                .help("Retract").accessibilityLabel("Retract Halo")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var conversationBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if conversation.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What can I do for you?").font(.system(size: 21, weight: .medium, design: .rounded))
                            Text("Ask anything, or say “Hey Mercy”.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.top, 20).padding(.bottom, 18)
                    }
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            if message.isUser {
                                Text(message.text).font(.system(size: 13)).textSelection(.enabled)
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                Text(renderedAssistantText(message))
                                    .font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.horizontal, 18).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: scrollKey) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func renderedAssistantText(_ message: Message) -> AttributedString {
        guard !message.text.isEmpty else { return AttributedString("Thinking…") }
        // Parsing Markdown changes glyph geometry. Keep the live row cheap and stable,
        // then render Markdown once the response is complete.
        if conversation.isResponding, message.id == conversation.messages.last?.id {
            return AttributedString(message.text)
        }
        return markdown(message.text)
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    private func approvalCard(_ approval: MacTools.Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.title, systemImage: "hand.raised").font(.system(size: 12, weight: .semibold))
            Text(approval.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            if let data = approval.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Screenshot preview for \(macTools.modelProviderName)")
            }
            ScrollView { Text(approval.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 100)
            HStack {
                Button("Cancel") { macTools.resolve(id: approval.id, allow: false) }.buttonStyle(.bordered)
                Spacer()
                Button("Allow once") { macTools.resolve(id: approval.id, allow: true) }.buttonStyle(.borderedProminent)
            }.controlSize(.small)
        }.padding(12)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var appChoices: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Which app?").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(catalog.suggestions) { app in
                Button { voice.cancel(); catalog.choose(app, conversation: conversation) } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 20, height: 20)
                        Text(app.name).font(.system(size: 12)); Spacer()
                    }.padding(5)
                }.buttonStyle(.plain)
            }
            Button("Cancel") { catalog.cancelSuggestion(); voice.cancel() }.font(.caption)
        }.padding(12)
    }

    private var speechStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !voice.notice.isEmpty { Text(voice.notice).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !voice.transcript.isEmpty && (voice.phase != .idle || !voice.notice.isEmpty) {
                Text(voice.phase == .idle ? "Last heard: \(voice.transcript)" : voice.transcript)
                    .font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                if voice.phase == .idle { conversation.stop(); voice.stopSpeaking() }
                wake.manual(voice: voice)
            } label: {
                Image(systemName: voice.phase == .listening ? "checkmark" : voice.phase == .idle ? "mic" : "xmark")
                    .font(.system(size: 14)).frame(width: 28, height: 30)
            }
            .buttonStyle(.plain).foregroundStyle(voice.phase == .listening ? ice : .secondary)
            .accessibilityLabel(voice.phase == .listening ? "Finish speaking and send" : "Microphone")
            TextField("Ask Mercy…", text: $draft, axis: .vertical)
                .font(.system(size: 13)).lineLimit(1...4).textFieldStyle(.plain).focused($composerFocused)
                .padding(.vertical, 7).onSubmit(send).accessibilityLabel("Message to Halo")
            if busy {
                Button { voice.cancel(); catalog.cancelSuggestion(); conversation.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10)).frame(width: 28, height: 30)
                }.buttonStyle(.plain).accessibilityLabel("Stop reply")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.8)).frame(width: 28, height: 28)
                        .background(ice.opacity(draft.isEmpty ? 0.35 : 1), in: Circle())
                }.buttonStyle(.plain).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        voice.cancel()
        conversation.send(text)
        draft = ""
        composerFocused = true
    }
}
