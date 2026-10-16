@preconcurrency import AVFoundation
import AppKit
import Observation
import Speech
import Synchronization
import HaloCore

private enum VoiceError: LocalizedError {
    case unavailable, microphone, format
    var errorDescription: String? {
        switch self {
        case .unavailable: "On-device English speech recognition is unavailable on this Mac."
        case .microphone: "Allow Halo in System Settings → Privacy & Security → Microphone, then try again."
        case .format: "The microphone audio format isn’t supported. Try another input device."
        }
    }
}

/// The tap owns this converter; no other thread accesses it.
private final class AudioFeed: @unchecked Sendable {
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    let converter: AVAudioConverter?

    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        self.continuation = continuation
        format = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        if input != output && converter == nil { throw VoiceError.format }
        converter?.primeMethod = .none
    }

    // Construct the callback here, outside VoiceController's MainActor context.
    // AVAudioEngine invokes this on its own audio queue.
    nonisolated func makeTap() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in append(buffer) }
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard let converter else {
            // AVAudioEngine reuses tap buffers: copy before passing to an async consumer.
            guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return }
            copy.frameLength = input.frameLength
            let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                guard let src = source[index].mData, let dst = destination[index].mData else { continue }
                memcpy(dst, src, Int(source[index].mDataByteSize))
            }
            continuation.yield(AnalyzerInput(buffer: copy))
            return
        }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let supplied = Mutex(false)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            let first = supplied.withLock { used in
                if used { return false }; used = true; return true
            }
            if !first { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return input
        }
        if error == nil && output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }
}

private final class TapInvocation: @unchecked Sendable {
    let callback: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    init(callback: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer) {
        self.callback = callback
        self.buffer = buffer
    }
    func run() { callback(buffer, AVAudioTime(sampleTime: 0, atRate: buffer.format.sampleRate)) }
}

@MainActor @Observable
final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, preparing, listening, finalizing }
    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var notice = ""
    private(set) var isSpeaking = false
    var speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "speakReplies")
            if !speakReplies { stopSpeaking() }
        }
    }
    var onTranscript: ((String) -> Void)?
    var onStart: (() -> Void)?
    var onRequestContent: (() -> Void)?
    @ObservationIgnored private var reportedRequest = false
    var contextualWords: [String] = ["Mercy", "Hey Mercy"]
    @ObservationIgnored private var externalAudioFeed: AudioFeed?
    @ObservationIgnored private var pendingSamples: [Float] = []
    @ObservationIgnored private var externalMode = false
    @ObservationIgnored private var pendingFinish = false
    @ObservationIgnored private var removeWake = false
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var feed: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var finalSegments: [String] = []
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static func checkAudioCallback() async throws {
        // Different rates force the same conversion path used by typical microphones.
        let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let audioFeed = try AudioFeed(input: input, output: output, continuation: continuation)
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800)!
        buffer.frameLength = 4800
        buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
        let invocation = TapInvocation(callback: audioFeed.makeTap(), buffer: buffer)
        await Task.detached { invocation.run() }.value
        continuation.finish()
        var count = 0
        for await _ in stream { count += 1 }
        guard count > 0 else { throw VoiceError.format }
    }

    static func checkSpeechFile(_ path: String) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw VoiceError.unavailable }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: file.processingFormat) else { throw VoiceError.format }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let audioFeed = try AudioFeed(input: file.processingFormat, output: format, continuation: continuation)
        let results = Task { () throws -> String in
            var segments: [String] = []
            for try await result in transcriber.results {
                if result.isFinal { segments.append(String(result.text.characters)) }
            }
            return segments.joined(separator: " ")
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw VoiceError.format }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            audioFeed.append(buffer)
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    func ownsAudioEngine(_ id: ObjectIdentifier) -> Bool {
        engine.map { ObjectIdentifier($0) == id } ?? false
    }

    func audioDeviceChanged() {
        cancel()
        notice = "Audio device changed. Tap the microphone to start a new request."
    }

    func toggleListening() {
        if phase == .listening { finishListening() }
        else if phase == .idle { startListening() }
        else { cancel() }
    }

    func startListening(externalAudio: Bool = false, seed: [Float] = [], stripWake: Bool = false) {
        cancel()
        onStart?()
        externalMode = externalAudio
        pendingSamples = seed
        removeWake = stripWake
        let id = UUID()
        generation = id
        phase = .preparing
        notice = "Preparing on-device speech…"
        transcript = ""
        finalSegments = []
        partial = ""
        setupTask = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation()
                guard allowed else { throw VoiceError.microphone }
                guard SpeechTranscriber.isAvailable,
                      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw VoiceError.unavailable }
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
                if await AssetInventory.status(forModules: [transcriber]) != .installed,
                   let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    notice = "Downloading Apple’s English speech model…"
                    try await request.downloadAndInstall()
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                let engine = externalAudio ? nil : AVAudioEngine()
                let input = engine?.inputNode.outputFormat(forBus: 0) ?? AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                guard input.sampleRate > 0, input.channelCount > 0,
                      let output = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: input) else { throw VoiceError.format }
                try Task.checkCancellation()
                guard generation == id else { return }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                // Bounded input; an overloaded recognizer cannot grow the audio buffer indefinitely.
                let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
                self.feed = feed
                let audioFeed = try AudioFeed(input: input, output: output, continuation: feed)
                resultsTask = Task {
                    do {
                        for try await result in transcriber.results {
                            guard generation == id else { return }
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            if result.isFinal { finalSegments.append(text); partial = "" }
                            else { partial = text }
                            transcript = (finalSegments + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
                            let request = removeWake ? WakeTranscript.request(from: transcript) ?? "" : transcript
                            if !request.isEmpty && !reportedRequest {
                                reportedRequest = true
                                onRequestContent?()
                            }
                        }
                    } catch {
                        guard generation == id else { return }
                        cancel()
                        notice = "Recognition failed: \(error.localizedDescription)"
                    }
                }
                let context = AnalysisContext()
                context.contextualStrings[.general] = ["Mercy", "Hey Mercy"] + Array(contextualWords.prefix(150))
                try await analyzer.setContext(context)
                try await analyzer.prepareToAnalyze(in: output)
                try await analyzer.start(inputSequence: stream)
                try Task.checkCancellation()
                guard generation == id else { return }
                if let engine {
                    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input, block: audioFeed.makeTap())
                    self.engine = engine
                    engine.prepare()
                    try engine.start()
                } else {
                    externalAudioFeed = audioFeed
                    let buffered = pendingSamples
                    pendingSamples = []
                    appendExternal(buffered)
                }
                phase = .listening
                notice = externalAudio ? "Listening… speak naturally; I’ll send when you finish" : "Listening… tap the microphone again to send"
                if pendingFinish { finishListening(); return }
                timeoutTask = Task {
                    try? await Task.sleep(for: .seconds(30))
                    if !Task.isCancelled && generation == id { finishListening() }
                }
            } catch {
                guard generation == id else { return }
                cancel()
                notice = error is CancellationError ? "Cancelled" : error.localizedDescription
            }
        }
    }

    func receiveExternalAudio(_ samples: [Float]) {
        guard externalMode && (phase == .preparing || phase == .listening) else { return }
        if externalAudioFeed != nil { appendExternal(samples) }
        else {
            // Keep a bounded request buffer while the on-device recognizer prepares.
            if pendingSamples.count + samples.count <= 480000 { pendingSamples += samples }
            else { cancel(); notice = "Speech setup took too long. Please try again." }
        }
    }

    private func appendExternal(_ samples: [Float]) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
        }
        externalAudioFeed?.append(pcm)
    }

    func finishWhenReady() {
        if phase == .preparing { pendingFinish = true }
        else if phase == .listening { finishListening() }
    }

    func finishListening() {
        guard phase == .listening else { return }
        let id = generation
        phase = .finalizing
        notice = "Finishing transcript…"
        stopCapture()
        feed?.finish()
        timeoutTask?.cancel()
        // If finalization stalls, return control instead of leaving the UI stuck.
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled && generation == id {
                cancel()
                notice = "Speech recognition timed out. Tap the microphone to try again."
            }
        }
        setupTask = Task {
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
                await resultsTask?.value
                guard generation == id else { return }
                var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let wakeConfirmed = !removeWake || WakeTranscript.request(from: text) != nil
                if removeWake { text = WakeTranscript.request(from: text) ?? "" }
                timeoutTask?.cancel()
                phase = .idle
                analyzer = nil
                feed = nil
                externalAudioFeed = nil
                pendingSamples = []
                externalMode = false
                resultsTask = nil
                if !wakeConfirmed { notice = "The wake detector heard Mercy, but transcription couldn’t confirm the phrase. Try again or use the microphone button." }
                else if text.isEmpty { notice = removeWake ? "I heard the wake phrase but didn’t catch the request after it. Try again or use the microphone button." : "I didn’t catch that. Tap the microphone to try again." }
                else { notice = "" }
                if !text.isEmpty { onTranscript?(text) }
            } catch {
                guard generation == id else { return }
                cancel()
                notice = "Couldn’t finish recognition: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        generation = UUID()
        onRequestContent = nil
        reportedRequest = false
        externalAudioFeed = nil
        pendingSamples = []
        externalMode = false
        pendingFinish = false
        removeWake = false
        setupTask?.cancel()
        setupTask = nil
        timeoutTask?.cancel()
        resultsTask?.cancel()
        resultsTask = nil
        stopCapture()
        feed?.finish()
        feed = nil
        if let previous = analyzer { Task { await previous.cancelAndFinishNow() } }
        analyzer = nil
        phase = .idle
        notice = ""
        stopSpeaking()
    }

    private func stopCapture() {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    func speak(_ text: String) {
        guard speakReplies, phase == .idle, !text.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = self?.synthesizer.isSpeaking ?? false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = self?.synthesizer.isSpeaking ?? false }
    }
}
