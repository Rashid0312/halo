@preconcurrency import AVFoundation
import CWake
import HaloCore
import Observation
import Synchronization

enum WakeFailure: LocalizedError {
    case models, microphone, noRequest
    var errorDescription: String? {
        switch self {
        case .noRequest: "The voice check produced no request transcript."
        case .models: "The local wake models could not be loaded. You can still use the talk button."
        case .microphone: "Enable Halo’s microphone access in System Settings to use hands-free mode."
        }
    }
}

/// All inference and request bookkeeping run on one serial worker queue.
private final class WakeWorker: @unchecked Sendable {
    enum Event: Sendable { case trigger([Float], Bool), audio([Float]), end }
    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "app.halo.wake", qos: .userInitiated)
    private var detector: OpaquePointer?
    private enum Mode { case paused, waiting, capturing }
    private var mode = Mode.paused
    private var preRoll: [Float] = []
    private var vadBuffer: [Float] = []
    private var endpoint = RequestEndpoint()
    // Bound queued work, too, rather than letting a slow device accumulate audio.
    private let queued = Mutex(0)

    init(resources: URL) throws {
        (events, continuation) = AsyncStream<Event>.makeStream()
        let model = resources.appendingPathComponent("models")
        let kws = model.appendingPathComponent("sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")
        let paths = ["encoder", "decoder", "joiner"].map {
            kws.appendingPathComponent("\($0)-epoch-12-avg-2-chunk-16-left-64.int8.onnx").path
        } + [kws.appendingPathComponent("tokens.txt").path,
             resources.appendingPathComponent("wake-keywords.txt").path,
             model.appendingPathComponent("silero_vad.onnx").path]
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else { throw WakeFailure.models }
        let strings = paths.map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        detector = halo_wake_create(strings[0], strings[1], strings[2], strings[3], strings[4], strings[5])
        guard detector != nil else { throw WakeFailure.models }
    }

    deinit { halo_wake_destroy(detector); continuation.finish() }

    func resume() {
        queue.async { [self] in
            guard mode != .waiting else { return }
            halo_wake_reset(detector)
            preRoll = []; vadBuffer = []
            mode = .waiting
        }
    }

    func pause() {
        queue.async { [self] in mode = .paused; preRoll = []; vadBuffer = [] }
    }

    func manual() {
        queue.async { [self] in begin(seed: [], wake: false) }
    }

    func confirmRequest() {
        queue.async { [self] in endpoint.confirmRequest() }
    }

    private func begin(seed: [Float], wake: Bool) {
        halo_wake_reset(detector)
        mode = .capturing
        vadBuffer = []
        endpoint = RequestEndpoint()
        // Seed VAD with the same pre-roll used by transcription, so even a
        // short request already underway at detection can end promptly.
        for offset in stride(from: 0, to: seed.count - seed.count % 512, by: 512) {
            let frame = Array(seed[offset..<offset + 512])
            frame.withUnsafeBufferPointer { _ = halo_vad_accept(detector, $0.baseAddress, 512) }
        }
        continuation.yield(.trigger(seed, wake))
    }

    func accept(_ samples: [Float]) {
        let allowed = queued.withLock { count in
            if count >= 64 { return false }; count += 1; return true
        }
        guard allowed else { return }
        queue.async { [self] in
            defer { queued.withLock { $0 -= 1 } }
            guard let detector else { return }
            switch mode {
            case .paused: break
            case .waiting:
                preRoll += samples
                if preRoll.count > 32000 { preRoll.removeFirst(preRoll.count - 32000) }
                let hit = samples.withUnsafeBufferPointer { halo_wake_accept(detector, $0.baseAddress, Int32($0.count)) }
                if hit != 0 { begin(seed: preRoll, wake: true); preRoll = [] }
            case .capturing:
                continuation.yield(.audio(samples))
                var speechDetected = false
                vadBuffer += samples
                while vadBuffer.count >= 512 {
                    let frame = Array(vadBuffer.prefix(512))
                    vadBuffer.removeFirst(512)
                    let speech = frame.withUnsafeBufferPointer { halo_vad_accept(detector, $0.baseAddress, 512) != 0 }
                    speechDetected = speechDetected || speech
                }
                if endpoint.observe(sampleCount: samples.count, speechDetected: speechDetected) {
                    mode = .paused
                    continuation.yield(.end)
                }
            }
        }
    }

    /// Same detector, fed in microphone-sized blocks; used by synthetic regression checks.
    func check(samples: [Float]) -> Bool {
        guard let detector else { return false }
        for offset in stride(from: 0, to: samples.count, by: 512) {
            let frame = Array(samples[offset..<min(offset + 512, samples.count)])
            if frame.withUnsafeBufferPointer({ halo_wake_accept(detector, $0.baseAddress, Int32($0.count)) }) != 0 { return true }
        }
        return false
    }
}

/// Created outside the main actor: AVAudioEngine invokes its callback on an audio queue.
private final class WakeAudioTap: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let worker: WakeWorker
    init(input: AVAudioFormat, worker: WakeWorker) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: input, to: format) else { throw WakeFailure.microphone }
        self.converter = converter
        self.converter.primeMethod = .none
        self.worker = worker
    }
    nonisolated func callback() -> AVAudioNodeTapBlock {
        { [self] input, _ in
            let size = AVAudioFrameCount(Double(input.frameLength) * 16000 / input.format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { return }
            let used = Mutex(false)
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                let first = used.withLock { value in if value { return false }; value = true; return true }
                status.pointee = first ? .haveData : .noDataNow
                return first ? input : nil
            }
            if error == nil, let data = output.floatChannelData?[0], output.frameLength > 0 {
                worker.accept(Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))))
            }
        }
    }
}

@MainActor @Observable
final class WakeController {
    private(set) var enabled = false
    private(set) var running = false
    private(set) var status = "Hands-free off"
    var onWake: (() -> Void)?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var worker: WakeWorker?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var rearmed = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var resumeAfter = Date.distantPast

    func ownsAudioEngine(_ id: ObjectIdentifier) -> Bool {
        engine.map { ObjectIdentifier($0) == id } ?? false
    }

    func setEnabled(_ enabled: Bool, voice: VoiceController, conversation: HaloCore.Conversation) {
        voice.cancel()
        stop()
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "wakeEnabled")
        guard enabled else { voice.cancel(); return }
        let id = UUID(); generation = id
        status = "Starting local wake detection…"
        task = Task {
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw WakeFailure.microphone }
                try Task.checkCancellation()
                guard generation == id, let resources = Bundle.main.resourceURL else { return }
                let worker = try await Task.detached { try WakeWorker(resources: resources) }.value
                try Task.checkCancellation()
                guard generation == id else { return }
                let engine = AVAudioEngine()
                let input = engine.inputNode.outputFormat(forBus: 0)
                guard input.sampleRate > 0 && input.channelCount > 0 else { throw WakeFailure.microphone }
                let tap = try WakeAudioTap(input: input, worker: worker)
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input, block: tap.callback())
                self.engine = engine
                self.worker = worker
                engine.prepare()
                try engine.start()
                running = true
                rearmed = false
                monitor = Task {
                    while !Task.isCancelled && generation == id {
                        let nowBusy = voice.phase != .idle || voice.isSpeaking || conversation.isResponding
                        if nowBusy {
                            if voice.phase == .finalizing || voice.phase == .idle { worker.pause() }
                            rearmed = false
                            busy = true
                            status = "Hands-free paused during your request"
                        } else {
                            if busy { resumeAfter = Date().addingTimeInterval(0.8); busy = false }
                            if !rearmed && Date() >= resumeAfter {
                                worker.resume(); rearmed = true
                                status = "Listening for Mercy or Hey Mercy"
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                for await event in worker.events {
                    guard generation == id else { return }
                    switch event {
                    case .trigger(let seed, let wake):
                        guard !voice.isSpeaking && !conversation.isResponding else { worker.pause(); continue }
                        rearmed = false
                        onWake?()
                        voice.startListening(externalAudio: true, seed: seed, stripWake: wake)
                        voice.onRequestContent = { worker.confirmRequest() }
                    case .audio(let samples): voice.receiveExternalAudio(samples)
                    case .end: voice.finishWhenReady()
                    }
                }
            } catch {
                guard generation == id else { return }
                stop()
                status = "Hands-free unavailable: \(error.localizedDescription)"
            }
        }
    }

    func manual(voice: VoiceController) {
        if voice.phase == .listening { voice.finishListening() }
        else if voice.phase != .idle { voice.cancel() }
        else if running { worker?.manual() }
        else { voice.toggleListening() }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        monitor?.cancel(); monitor = nil
        worker?.pause()
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; worker = nil
        running = false; enabled = false; rearmed = false; busy = false
        status = "Hands-free off"
    }

    static func checkRequestFile(_ path: String, voice: VoiceController) async throws -> String {
        guard let resources = Bundle.main.resourceURL else { throw WakeFailure.models }
        let worker = try WakeWorker(resources: resources)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw WakeFailure.microphone }
        try file.read(into: pcm)
        let samples = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))) + [Float](repeating: 0, count: 48000)
        var result = ""
        voice.onTranscript = { result = $0 }
        let consumer = Task {
            for await event in worker.events {
                switch event {
                case .trigger(let seed, let wake):
                    voice.startListening(externalAudio: true, seed: seed, stripWake: wake)
                    voice.onRequestContent = { worker.confirmRequest() }
                case .audio(let samples): voice.receiveExternalAudio(samples)
                case .end: voice.finishWhenReady()
                }
            }
        }
        defer { consumer.cancel(); worker.pause(); voice.cancel() }
        worker.resume()
        for offset in stride(from: 0, to: samples.count, by: 512) {
            worker.accept(Array(samples[offset..<min(offset + 512, samples.count)]))
            try await Task.sleep(for: .milliseconds(4))
        }
        for _ in 0..<200 {
            if !result.isEmpty { return result }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WakeFailure.noRequest
    }

    static func checkFile(_ path: String) throws -> Bool {
        guard let resources = Bundle.main.resourceURL else { throw WakeFailure.models }
        let worker = try WakeWorker(resources: resources)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw WakeFailure.microphone }
        try file.read(into: pcm)
        let samples = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength))) + [Float](repeating: 0, count: 16000)
        return worker.check(samples: samples)
    }
}
