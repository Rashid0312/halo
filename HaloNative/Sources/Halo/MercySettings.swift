import SwiftUI
import AppKit
import HaloCore

/// Settings: a sidebar of grouped pages with search, and rows that show the
/// current value and open a pop-up to change it.
struct MercySettings: View {
    @Bindable var voice: VoiceController
    @Bindable var wake: WakeController
    let setHandsFree: (Bool) -> Void
    @Bindable var catalog: AppCatalog
    @Bindable var macTools: MacTools
    @Bindable var presentation: PanelPresentation
    @Bindable var auth: ChatGPTAuth
    @Bindable var browserBridge: BrowserBridgeController
    @Bindable var connectorAccounts: ConnectorAccounts
    let deepSeekKey: DeepSeekKey
    let runSetup: () -> Void

    @AppStorage("recordTraces") private var recordTraces = false
    @AppStorage("userName") private var userName = ""
    @State private var traceCount = 0
    @State private var page: Page = .general
    @State private var search = ""
    @State private var popup: Popup?
    @State private var keyDraft = ""
    @State private var keyError = ""
    @State private var hasKey = false

    init(voice: VoiceController, wake: WakeController, setHandsFree: @escaping (Bool) -> Void, catalog: AppCatalog,
         macTools: MacTools, presentation: PanelPresentation, auth: ChatGPTAuth, browserBridge: BrowserBridgeController,
         connectorAccounts: ConnectorAccounts, deepSeekKey: DeepSeekKey, runSetup: @escaping () -> Void, startPage: Page = .general) {
        self.voice = voice; self.wake = wake; self.setHandsFree = setHandsFree; self.catalog = catalog; self.macTools = macTools
        self.presentation = presentation; self.auth = auth; self.browserBridge = browserBridge
        self.connectorAccounts = connectorAccounts; self.deepSeekKey = deepSeekKey; self.runSetup = runSetup
        _page = State(initialValue: startPage)
    }

    enum Page: String, CaseIterable, Identifiable {
        case general, voice, brain, apps, access, browser, privacy, problems
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .voice: "Voice"
            case .brain: "Brain & account"
            case .apps: "Apps"
            case .access: "Mac access"
            case .browser: "Browser"
            case .privacy: "Privacy & data"
            case .problems: "Problems"
            }
        }

        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .voice: "waveform"
            case .brain: "sparkles"
            case .apps: "square.grid.2x2"
            case .access: "hand.raised"
            case .browser: "globe"
            case .privacy: "lock.shield"
            case .problems: "exclamationmark.triangle"
            }
        }

        var group: String {
            switch self {
            case .general, .voice, .brain: Mercy.name
            case .apps, .access, .browser: "Your Mac"
            case .privacy, .problems: "Privacy"
            }
        }

        /// Words a search for this page should match besides its title.
        var keywords: [String] {
            switch self {
            case .general: ["corner", "bar", "panel", "setup", "name", "finder", "gradient"]
            case .voice: ["wake", "hey", "listen", "microphone", "speak", "replies", "deepgram"]
            case .brain: ["chatgpt", "deepseek", "key", "model", "sign in", "sign out", "provider"]
            case .apps: ["connect", "connector", "oauth", "installed", "spoken names"]
            case .access: ["accessibility", "screen", "recording", "permission", "approve", "full disk"]
            case .browser: ["chrome", "extension", "bridge", "tabs"]
            case .privacy: ["training", "conversations", "hide", "emails", "phone", "card", "scrub"]
            case .problems: ["errors", "failures", "log"]
            }
        }
    }

    private enum Popup: String, Identifiable {
        case brain, deepSeekKey, chatGPTModel
        var id: Self { self }
    }

    private var groups: [(String, [Page])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let pages = Page.allCases.filter { page in
            query.isEmpty || page.title.lowercased().contains(query) || page.keywords.contains { $0.contains(query) }
        }
        return [Mercy.name, "Your Mac", "Privacy"].compactMap { group in
            let items = pages.filter { $0.group == group }
            return items.isEmpty ? nil : (group, items)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Mercy.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 10) {
                        Text(page.title).font(Mercy.pageTitle).foregroundStyle(Mercy.ink)
                        if let badge { Text(badge).font(Mercy.micro).foregroundStyle(Mercy.inkSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 3).background(Color.black.opacity(0.05), in: Capsule()) }
                    }
                    pageContent
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 36).padding(.vertical, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(MercyBackdrop(strength: 0.22))
        .foregroundStyle(Mercy.ink)
        .tint(Mercy.accent)
        .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 680)
        .sheet(item: $popup) { popupContent($0).environment(\.colorScheme, .light) }
        // A light design: system controls must not draw in dark mode on light cards.
        .environment(\.colorScheme, .light)
        .onAppear { hasKey = deepSeekKey.isSet; traceCount = TraceRecorder.shared.count(); refreshAccess() }
        // macOS doesn't announce new grants; check whenever the window comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshAccess() }
    }

    private var badge: String? {
        switch page {
        case .brain: auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek"
        case .access: macTools.ui.trusted && macTools.screen.allowed ? nil : "Action needed"
        default: nil
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                MercyMark(size: 18)
                Text(Mercy.name.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(2.2)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Mercy.inkFaint)
                TextField("Search settings…", text: $search).textFieldStyle(.plain).font(Mercy.body)
                    .onSubmit { if let first = groups.first?.1.first { page = first; search = "" } }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: Mercy.chipRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mercy.chipRadius, style: .continuous).strokeBorder(Mercy.hairline))
            .padding(.horizontal, 12).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if groups.isEmpty {
                        Text("Nothing for “\(search.trimmingCharacters(in: .whitespaces))”.").font(Mercy.body)
                            .foregroundStyle(Mercy.inkSecondary).padding(.horizontal, 20)
                    }
                    ForEach(groups, id: \.0) { group, items in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group).font(Mercy.micro).foregroundStyle(Mercy.inkFaint).padding(.horizontal, 20).padding(.bottom, 4)
                            ForEach(items) { item in railItem(item) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(Mercy.caption).foregroundStyle(Mercy.inkFaint).textSelection(.enabled)
                .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 236)
        .background(Mercy.rail)
    }

    private func railItem(_ item: Page) -> some View {
        let selected = item == page
        return Button { page = item; search = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(selected ? Mercy.accent : Mercy.inkSecondary)
                Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if item == .access, !(macTools.ui.trusted && macTools.screen.allowed) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? Mercy.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Mercy.chipRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    // MARK: Pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
            MercyCard(title: "You") {
                MercyRow(icon: "person", title: "Your name", detail: "\(Mercy.name) uses it when talking to you.") {
                    TextField("First name", text: $userName).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(Mercy.body).frame(width: 160)
                }
                MercyRow(icon: "wand.and.stars", title: "Setup", detail: "Walk through sign-in, microphone, and permissions again.") {
                    Button("Run setup again", action: runSetup).buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
            MercyCard(title: "\(Mercy.name) bar", footer: "When off, \(Mercy.name) lives in the menu bar and slides away when idle. When on, it stays as a small capsule in the corner.") {
                MercyToggleRow(icon: "macwindow", title: "Keep in the corner", isOn: $presentation.keepInCorner)
            }
            MercyCard(title: "Application") {
                MercyRow(icon: "app.badge", title: "Halo.app", detail: Bundle.main.bundleURL.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        .buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
        case .voice:
            MercyCard(title: "Listening", footer: wake.status) {
                MercyToggleRow(icon: "ear", title: "Listen for “\(Mercy.name)” or “Hey \(Mercy.name)”",
                               detail: "Wake word detection runs on this Mac.",
                               isOn: Binding(get: { wake.enabled }, set: { setHandsFree($0) }))
                MercyRow(icon: "mic", title: "Recognition") { Text("Apple · On this Mac").font(Mercy.body).foregroundStyle(Mercy.inkSecondary) }
            }
            MercyCard(title: "Spoken replies", footer: "Microphone audio stays with Apple speech recognition. Only \(Mercy.name)'s reply text is sent to Deepgram to be spoken.") {
                MercyToggleRow(icon: "speaker.wave.2", title: "Speak replies", isOn: $voice.speakReplies)
                MercyRow(icon: "person.wave.2", title: "Voice") { Text("Deepgram Aura 2").font(Mercy.body).foregroundStyle(Mercy.inkSecondary) }
            }
        case .brain:
            MercyCard(title: "Brain", footer: "The brain writes \(Mercy.name)'s replies and chooses its actions. Actions always run on this Mac.") {
                MercyValueRow(icon: "sparkles", title: "Thinks with", value: auth.provider == "chatgpt" ? "ChatGPT" : "DeepSeek") { popup = .brain }
                if auth.provider == "chatgpt", auth.sharing, !auth.models.isEmpty {
                    MercyValueRow(icon: "cpu", title: "ChatGPT model",
                                  value: auth.models.first { $0.id == auth.selectedModel }?.name ?? auth.selectedModel) { popup = .chatGPTModel }
                }
            }
            MercyCard(title: "ChatGPT account", footer: auth.status.isEmpty ? nil : auth.status) {
                if auth.signedIn {
                    MercyRow(icon: "person.crop.circle", title: auth.email, detail: "Signed in") {
                        Button("Sign out") { Task { await auth.signOut() } }.buttonStyle(MercyButtonStyle(kind: .secondary))
                    }
                } else if auth.signingIn {
                    MercyRow(icon: "person.crop.circle", title: "Waiting for your browser…") {
                        Button("Cancel") { auth.cancelSignIn() }.buttonStyle(MercyButtonStyle(kind: .secondary))
                    }
                } else {
                    MercyRow(icon: "person.crop.circle", title: "Not signed in", detail: "Use your ChatGPT plan as \(Mercy.name)'s brain.") {
                        Button("Continue with ChatGPT") { auth.startSignIn() }.buttonStyle(MercyButtonStyle())
                    }
                }
                MercyRow(icon: "chart.bar", title: "Usage") {
                    Button("Manage on chatgpt.com") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage")!) }
                        .buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
            MercyCard(title: "DeepSeek") {
                MercyValueRow(icon: "key", title: "API key", value: hasKey ? "Saved on this Mac" : "Not set") { keyDraft = ""; keyError = ""; popup = .deepSeekKey }
            }
        case .apps:
            MercyCard {
                Form { AppCatalogSettings(catalog: catalog) }.formStyle(.grouped).scrollDisabled(true).scrollContentBackground(.hidden)
            }
            MercyCard {
                Form { ConnectorSettings(accounts: connectorAccounts) }.formStyle(.grouped).scrollDisabled(true).scrollContentBackground(.hidden)
            }
        case .access:
            MercyCard(title: "Permissions", footer: macTools.lastFailure.isEmpty ? "macOS asks you to approve each one. Granting a permission never bypasses \(Mercy.name)'s own approvals." : macTools.lastFailure) {
                MercyRow(icon: "accessibility", title: "Control Mac apps", detail: "Accessibility: click, type, and arrange windows.") {
                    MercyStatus(done: macTools.ui.trusted, doneText: "Allowed")
                    if !macTools.ui.trusted { Button("Allow…") { macTools.ui.requestAccess() }.buttonStyle(MercyButtonStyle(kind: .secondary)) }
                }
                MercyRow(icon: "rectangle.dashed.badge.record", title: "See the screen", detail: "Screen Recording: screenshots you approve.") {
                    MercyStatus(done: macTools.screen.allowed, doneText: "Allowed")
                    if !macTools.screen.allowed {
                        // Asking adds this exact build to the list; opening the pane alone can
                        // show an older copy with the same bundle ID.
                        Button("Allow…") { CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
                            .buttonStyle(MercyButtonStyle(kind: .secondary))
                    }
                }
                MercyRow(icon: "externaldrive", title: "Protected folders", detail: "Full Disk Access, only if you want \(Mercy.name) in Mail, Messages, and similar folders.") {
                    Button("Open…") { openPrivacy("Privacy_AllFiles") }.buttonStyle(MercyButtonStyle(kind: .secondary))
                }
                MercyRow(icon: "arrow.clockwise", title: "Check again") {
                    Button("Check access") { macTools.ui.refreshAccess(); macTools.screen.refreshAccess() }.buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
            MercyCard(title: "Approvals", footer: "When on, what you ask \(Mercy.name) to do happens without a confirmation; each step still appears in the activity list, and Stop ends it. Shell commands, AppleScript, file changes, and screenshots always ask. Sign-in, payments, account changes, sending messages, uploads, and downloads are never done in the browser.") {
                MercyToggleRow(icon: "globe", title: "Don't ask before browser actions", isOn: $macTools.autoApproveBrowser)
                MercyToggleRow(icon: "cursorarrow.click", title: "Don't ask before controlling Mac apps", isOn: $macTools.autoApproveMacUI)
            }
        case .browser:
            MercyCard(title: "Chrome", footer: "Lets \(Mercy.name) read and act in Chrome tabs: click, type, choose options, scroll, open addresses, submit ordinary forms, and follow links. Sign-in, payments, account changes, messages, uploads, and downloads stay blocked. Halo registers its native host only while this is on and accepts only its own extension.") {
                MercyToggleRow(icon: "puzzlepiece.extension", title: "Connect to the Halo browser extension",
                               detail: browserBridge.status.summary, isOn: $browserBridge.enabled)
            }
        case .privacy:
            MercyCard(title: "Connected apps", footer: "Results reach the model with those values replaced by labels such as [EMAIL_1]; when the model uses a label, Halo puts the real value back on this Mac just before calling the app, and approvals show the real values. Names and other personal text are not caught yet.") {
                MercyToggleRow(icon: "eye.slash", title: "Hide emails, phone and card numbers, and keys from the model", isOn: $macTools.privacyScrub)
            }
            MercyCard(title: "Training data", footer: "Off by default. When on, each request is saved on this Mac only: what you asked, the tools \(Mercy.name) used and their results, and the answer. Emails, phone and card numbers, keys, and your user name are replaced before saving; names and other personal text in pages or files are not. Screenshots are never saved. Nothing is uploaded.") {
                MercyToggleRow(icon: "tray.and.arrow.down", title: "Save conversations to train Halo's own model",
                               detail: "\(traceCount) saved so far", isOn: $recordTraces)
                    .onChange(of: recordTraces) { _, on in TraceRecorder.shared.isEnabled = on; traceCount = TraceRecorder.shared.count() }
                MercyRow(icon: "folder", title: "Saved conversations") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: TraceRecorder.shared.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([TraceRecorder.shared.directory])
                    }
                    .buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
        case .problems:
            let problems = FailureLog.shared.recent(500)
            MercyCard(title: "Recorded problems", footer: "Kept on this Mac only. Records which tool failed and why; never your messages, \(Mercy.name)'s replies, or what was sent to a tool.") {
                MercyRow(icon: "exclamationmark.triangle", title: problems.isEmpty ? "No failed requests recorded"
                         : "\(problems.count) failed request\(problems.count == 1 ? "" : "s") or tool error\(problems.count == 1 ? "" : "s")",
                         detail: problems.isEmpty ? nil : "Newest: \(problems[0]["detail"] as? String ?? "")")
                MercyRow(icon: "doc.text.magnifyingglass", title: "Problem log") {
                    Button("Show in Finder") {
                        if !FileManager.default.fileExists(atPath: FailureLog.shared.url.path) {
                            try? FileManager.default.createDirectory(at: FailureLog.shared.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            FileManager.default.createFile(atPath: FailureLog.shared.url.path, contents: nil)
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([FailureLog.shared.url])
                    }
                    .buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
        }
    }

    // MARK: Pop-ups

    @ViewBuilder private func popupContent(_ which: Popup) -> some View {
        switch which {
        case .brain:
            MercyPopup(title: "Brain", subtitle: "Which service writes \(Mercy.name)'s replies.", onClose: { popup = nil }) {
                VStack(spacing: 10) {
                    choice("DeepSeek", detail: hasKey ? "Uses your DeepSeek key." : "Needs a DeepSeek key.", selected: auth.provider == "deepseek") {
                        auth.provider = "deepseek"; popup = nil
                    }
                    choice("ChatGPT", detail: auth.sharing ? "Uses your ChatGPT plan." : "Sign in with ChatGPT first.", selected: auth.provider == "chatgpt") {
                        guard auth.sharing else { auth.startSignIn(); return }
                        auth.provider = "chatgpt"; popup = nil
                    }
                }
            }
        case .chatGPTModel:
            MercyPopup(title: "ChatGPT model", subtitle: "Faster models answer sooner; larger ones handle harder tasks.", onClose: { popup = nil }) {
                VStack(spacing: 8) {
                    ForEach(auth.models) { model in
                        choice(model.name, detail: nil, selected: auth.selectedModel == model.id) { auth.selectedModel = model.id; popup = nil }
                    }
                    Button("Refresh models") { Task { try? await auth.loadModels() } }.buttonStyle(MercyButtonStyle(kind: .secondary))
                }
            }
        case .deepSeekKey:
            MercyPopup(title: "DeepSeek key", subtitle: "Saved on this Mac only, never shown again. Takes effect right away.", onClose: { popup = nil }) {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("sk-…", text: $keyDraft).textFieldStyle(MercyFieldStyle())
                    if !keyError.isEmpty { Text(keyError).font(Mercy.caption).foregroundStyle(.red) }
                    HStack {
                        if hasKey { Button("Remove key") { saveKey("") }.buttonStyle(MercyButtonStyle(kind: .secondary)) }
                        Spacer()
                        Button("Save key") { saveKey(keyDraft) }.buttonStyle(MercyButtonStyle())
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    private func choice(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Mercy.rowTitle).foregroundStyle(Mercy.ink)
                    if let detail { Text(detail).font(Mercy.caption).foregroundStyle(Mercy.inkSecondary) }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Mercy.accent : Mercy.inkFaint)
            }
            .padding(14)
            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous).strokeBorder(selected ? Mercy.accent : Mercy.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func saveKey(_ key: String) {
        do {
            try deepSeekKey.save(key)
            hasKey = deepSeekKey.isSet
            popup = nil
        } catch { keyError = error.localizedDescription }
    }

    private func refreshAccess() { macTools.ui.refreshAccess(); macTools.screen.refreshAccess() }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
