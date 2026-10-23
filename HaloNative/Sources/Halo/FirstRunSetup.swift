@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// First-run setup, shown once: sign in to a brain, name, microphone check,
/// Mac permissions, voice, done. Settings can run it again.
@MainActor
final class FirstRunWindow {
    static let completedKey = "firstRunCompleted"
    private var window: NSWindow?

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    func show(auth: ChatGPTAuth, deepSeekKey: DeepSeekKey, macTools: MacTools, wake: WakeController,
              voice: VoiceController, setHandsFree: @escaping (Bool) -> Void, onFinish: @escaping () -> Void) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = FirstRunView(auth: auth, deepSeekKey: deepSeekKey, macTools: macTools, wake: wake, voice: voice,
                                setHandsFree: setHandsFree) { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            self?.window?.close()
            onFinish()
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum Step: Int, CaseIterable {
    case signIn, name, microphone, permissions, voice, ready
}

struct FirstRunView: View {
    @Bindable var auth: ChatGPTAuth
    let deepSeekKey: DeepSeekKey
    @Bindable var macTools: MacTools
    @Bindable var wake: WakeController
    @Bindable var voice: VoiceController
    let setHandsFree: (Bool) -> Void
    let finish: () -> Void

    @AppStorage("userName") private var userName = ""
    @AppStorage("lastSignInMethod") private var lastMethod = ""
    @State private var step: Step = .signIn
    @State private var keyEntry = false
    @State private var keyDraft = ""
    @State private var keyError = ""
    @State private var hasKey = false
    @State private var nameDraft = ""
    @State private var meter = MicrophoneMeter()

    init(auth: ChatGPTAuth, deepSeekKey: DeepSeekKey, macTools: MacTools, wake: WakeController, voice: VoiceController,
         setHandsFree: @escaping (Bool) -> Void, finish: @escaping () -> Void, startStep: Int = 0) {
        self.auth = auth; self.deepSeekKey = deepSeekKey; self.macTools = macTools; self.wake = wake; self.voice = voice
        self.setHandsFree = setHandsFree; self.finish = finish
        _step = State(initialValue: Step(rawValue: startStep) ?? .signIn)
    }

    var body: some View {
        ZStack {
            FluidGradient(configuration: .halo).background(Color(red: 0.42, green: 0.45, blue: 0.75)).ignoresSafeArea()
            Rectangle().fill(.black.opacity(0.08)).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 24)
                Group {
                    switch step {
                    case .signIn: signIn
                    case .name: nameStep
                    case .microphone: microphone
                    case .permissions: permissions
                    case .voice: voiceStep
                    case .ready: ready
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 36)
        }
        .foregroundStyle(.white)
        .frame(width: 560, height: 640)
        .animation(.spring(duration: 0.35), value: step)
        .onAppear { hasKey = deepSeekKey.isSet; nameDraft = userName }
        .onChange(of: step) { _, new in
            if new == .microphone { meter.start() } else { meter.stop() }
        }
        .onChange(of: auth.signingIn) { was, now in
            // A finished ChatGPT sign-in makes it the brain and moves on. Watch the
            // sign-in ending, not signedIn: signing in again while already signed in
            // leaves signedIn unchanged.
            if was, !now, auth.signedIn, step == .signIn { useChatGPT() }
        }
        .onDisappear { meter.stop() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            MercyMark(size: 20, color: .white.opacity(0.9))
            Text(Mercy.name.uppercased()).font(.system(size: 13, weight: .semibold)).tracking(2.6).opacity(0.9)
            Spacer()
            if step != .signIn, step != .ready {
                Button { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .signIn } } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).opacity(0.75)
            }
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(.white.opacity(item.rawValue <= step.rawValue ? 0.95 : 0.3))
                        .frame(width: item == step ? 18 : 6, height: 6)
                }
            }
            .padding(.leading, 8)
        }
    }

    private func title(_ text: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(Mercy.heroTitle).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(Mercy.heroBody).opacity(0.78).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advance() {
        withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .ready }
    }

    // MARK: Steps

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 26) {
            title("Hi, I'm \(Mercy.name).", "I work on this Mac: your apps, files, and browser. Choose the brain I think with to get started.")
            VStack(spacing: 10) {
                if auth.signingIn {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Finish signing in in your browser…").font(Mercy.body)
                        Spacer()
                        Button("Cancel") { auth.cancelSignIn() }.buttonStyle(.plain).font(Mercy.body).opacity(0.8)
                    }
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
                } else if auth.signedIn && auth.sharing {
                    Button(action: useChatGPT) {
                        HStack { Image(systemName: "sparkles"); Text("Continue as \(auth.email)").lineLimit(1); Spacer(); lastUsed("chatgpt") }
                    }
                    .buttonStyle(MercyButtonStyle(kind: .onGradient, wide: true))
                    Button("Use a different ChatGPT account") { auth.startSignIn() }.buttonStyle(.plain).font(Mercy.caption).opacity(0.75)
                } else {
                    Button { auth.startSignIn() } label: {
                        HStack { Image(systemName: "sparkles"); Text("Continue with ChatGPT"); Spacer(); lastUsed("chatgpt") }
                    }
                    .buttonStyle(MercyButtonStyle(kind: .onGradient, wide: true))
                }
                if hasKey && !keyEntry {
                    Button { lastMethod = "deepseek"; auth.provider = "deepseek"; advance() } label: {
                        HStack { Image(systemName: "key.fill"); Text("Continue with DeepSeek"); Spacer(); lastUsed("deepseek")
                            Text("Key on this Mac").font(Mercy.micro).opacity(0.8) }
                    }
                    .buttonStyle(MercyButtonStyle(kind: .glass, wide: true))
                    Button("Use a different DeepSeek key") { keyEntry = true }.buttonStyle(.plain).font(Mercy.caption).opacity(0.75)
                } else if keyEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("Paste your DeepSeek API key", text: $keyDraft)
                            .textFieldStyle(MercyFieldStyle(onGradient: true)).onSubmit(saveKey)
                        if !keyError.isEmpty { Text(keyError).font(Mercy.caption) }
                        HStack {
                            Button("Cancel") { keyEntry = false; keyDraft = "" }.buttonStyle(.plain).font(Mercy.body).opacity(0.8)
                            Spacer()
                            Button("Save and continue", action: saveKey).buttonStyle(MercyButtonStyle(kind: .onGradient))
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                } else {
                    Button { keyEntry = true } label: { HStack { Image(systemName: "key"); Text("Use a DeepSeek key"); Spacer() } }
                        .buttonStyle(MercyButtonStyle(kind: .glass, wide: true))
                }
                if !auth.status.isEmpty { Text(auth.status).font(Mercy.caption).opacity(0.8).frame(maxWidth: .infinity, alignment: .leading) }
            }
            Text("Your conversations stay on this Mac. Only your requests go to the brain you choose, and \(Mercy.name) asks before anything outside it is changed.")
                .font(Mercy.caption).opacity(0.68).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func lastUsed(_ method: String) -> some View {
        if lastMethod == method {
            Text("Last used").font(Mercy.micro).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Mercy.accent.opacity(0.15), in: Capsule()).foregroundStyle(Mercy.accent)
        }
    }

    private func useChatGPT() {
        lastMethod = "chatgpt"
        if auth.sharing { auth.provider = "chatgpt" }
        advance()
    }

    private func saveKey() {
        do {
            try deepSeekKey.save(keyDraft)
            guard deepSeekKey.isSet else { keyError = "That key is empty."; return }
            hasKey = true; keyEntry = false; keyDraft = ""; keyError = ""
            lastMethod = "deepseek"; auth.provider = "deepseek"
            advance()
        } catch { keyError = error.localizedDescription }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            title("What's your name?", "So I know what to call you.")
            TextField("First name", text: $nameDraft).textFieldStyle(MercyFieldStyle(onGradient: true))
                .onSubmit { if !nameDraft.isEmpty { userName = nameDraft; advance() } }
            HStack {
                Button("Not now") { advance() }.buttonStyle(.plain).font(Mercy.body).opacity(0.8)
                Spacer()
                Button("Continue") { userName = nameDraft.trimmingCharacters(in: .whitespaces); advance() }
                    .buttonStyle(MercyButtonStyle(kind: .onGradient))
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 26) {
            title("Let's check your microphone", meter.state == .denied
                  ? "macOS hasn't given me the microphone. You can allow it in System Settings, or keep typing instead."
                  : "Say something, like “Hey \(Mercy.name), what's on my calendar?”")
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<28, id: \.self) { index in
                    let level = meter.level * (0.55 + 0.45 * sin(Double(index) * 0.9 + meter.phase))
                    Capsule().fill(.white.opacity(meter.heard ? 0.95 : 0.7))
                        .frame(width: 6, height: max(6, 70 * level))
                }
            }
            .frame(height: 80, alignment: .center).frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Mercy.cardRadius, style: .continuous))
            Label(meter.heard ? "I can hear you." : meter.state == .denied ? "Microphone not allowed" : "Listening…",
                  systemImage: meter.heard ? "checkmark.circle.fill" : meter.state == .denied ? "mic.slash" : "waveform")
                .font(Mercy.rowTitle).opacity(0.9)
            HStack {
                if meter.state == .denied {
                    Button("Open System Settings") { openPrivacy("Privacy_Microphone") }.buttonStyle(.plain).font(Mercy.body).opacity(0.85)
                } else {
                    Button("Skip") { advance() }.buttonStyle(.plain).font(Mercy.body).opacity(0.8)
                }
                Spacer()
                Button("Continue") { advance() }.buttonStyle(MercyButtonStyle(kind: .onGradient))
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 26) {
            title("Let me use your Mac", "Two macOS permissions let me act for you. I still ask before each action unless you turn that off.")
            VStack(spacing: 10) {
                permissionRow(icon: "accessibility", title: "Control apps", detail: "Click, type, and arrange windows.",
                              done: macTools.ui.trusted) { macTools.ui.requestAccess() }
                permissionRow(icon: "rectangle.dashed.badge.record", title: "See the screen", detail: "Only screenshots you approve.",
                              done: macTools.screen.allowed) { CGRequestScreenCaptureAccess(); openPrivacy("Privacy_ScreenCapture") }
            }
            HStack {
                Button("Later") { advance() }.buttonStyle(.plain).font(Mercy.body).opacity(0.8)
                Spacer()
                Button("Continue") { advance() }.buttonStyle(MercyButtonStyle(kind: .onGradient))
            }
        }
        .task {
            // macOS reports a new grant without telling the app; check every second here.
            while !Task.isCancelled {
                macTools.ui.refreshAccess(); macTools.screen.refreshAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, done: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Mercy.rowTitle)
                Text(detail).font(Mercy.caption).opacity(0.75)
            }
            Spacer()
            if done {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(Mercy.micro)
            } else {
                Button("Allow", action: allow).buttonStyle(MercyButtonStyle(kind: .onGradient))
            }
        }
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.22)))
    }

    private var voiceStep: some View {
        VStack(alignment: .leading, spacing: 26) {
            title("How should we talk?", "You can always type. Voice is optional, and listening for my name happens on this Mac.")
            VStack(spacing: 10) {
                toggleRow(icon: "ear", title: "Listen for “Hey \(Mercy.name)”", detail: "Say my name to start, hands free.",
                          isOn: Binding(get: { wake.enabled }, set: { setHandsFree($0) }))
                toggleRow(icon: "speaker.wave.2", title: "Speak my replies", detail: "Turn off to only read them.", isOn: $voice.speakReplies)
            }
            HStack {
                Spacer()
                Button("Continue") { advance() }.buttonStyle(MercyButtonStyle(kind: .onGradient))
            }
        }
    }

    private func toggleRow(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 16, weight: .medium)).frame(width: 36, height: 36)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Mercy.rowTitle)
                Text(detail).font(Mercy.caption).opacity(0.75)
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(.white.opacity(0.9))
        }
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous).strokeBorder(.white.opacity(0.22)))
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 26) {
            title(userName.isEmpty ? "You're all set." : "You're all set, \(userName).",
                  wake.enabled ? "Say “Hey \(Mercy.name)”, or click my icon in the menu bar. Try one of these:" : "Click my icon in the menu bar and ask. Try one of these:")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["Open Spotify and play something calm", "Summarize the page I'm reading", "Move this window to the left half"], id: \.self) { example in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                        Text(example).font(Mercy.heroBody)
                    }
                    .padding(.horizontal, 14).frame(height: 40)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
                }
            }
            HStack {
                Spacer()
                Button("Start using \(Mercy.name)", action: finish).buttonStyle(MercyButtonStyle(kind: .onGradient)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

/// Input level for the microphone check, from a throwaway metering recorder
/// (nothing is kept: it records to a temporary file that is deleted).
@MainActor @Observable
final class MicrophoneMeter {
    enum State { case idle, listening, denied }
    private(set) var state: State = .idle
    private(set) var level: Double = 0
    private(set) var heard = false
    private(set) var phase: Double = 0
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("mercy-mic-check.caf")

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .audio) else { self?.state = .denied; return }
            guard let self, !Task.isCancelled else { return }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleIMA4, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
            guard let recorder = try? AVAudioRecorder(url: file, settings: settings) else { state = .denied; return }
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            state = .listening
            while !Task.isCancelled {
                recorder.updateMeters()
                // -50 dB (quiet room) to -10 dB (speaking up close) mapped to 0…1.
                let value = max(0, min(1, (Double(recorder.averagePower(forChannel: 0)) + 50) / 40))
                level = level * 0.6 + value * 0.4
                phase += 0.35
                if value > 0.45 { heard = true }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        recorder?.stop(); recorder?.deleteRecording(); recorder = nil
        level = 0
        if state == .listening { state = .idle }
    }
}
