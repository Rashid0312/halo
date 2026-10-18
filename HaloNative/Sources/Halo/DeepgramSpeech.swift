@preconcurrency import AVFoundation
import Foundation

private enum DeepgramSpeechError: LocalizedError {
    case invalidEndpoint, audio
    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Deepgram voice could not be configured."
        case .audio: "The Mac audio output could not start."
        }
    }
}

@MainActor
final class DeepgramSpeech {
    static let sampleRate = 24_000.0
    static let model = "aura-2-andromeda-en"

    var onSpeakingChanged: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let key: String
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var generation = UUID()
    private var pendingFlushes = 0
    private var scheduledBuffers = 0
    private var responseFinished = false
    private var dropping = false
    private var hasSpokenAudio = false
    private var playbackStarted = false
    private var queuedFrames: AVAudioFrameCount = 0
    private static let prebufferSeconds = 0.35

    init(key: String) {
        self.key = key
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    var isAvailable: Bool { !key.isEmpty }

    func warm() {
        guard isAvailable else { return }
        idleTask?.cancel()
        do { try connectIfNeeded() }
        catch { fail(error) }
    }

    func beginResponse() {
        guard isAvailable else { return }
        idleTask?.cancel()
        responseFinished = false
        pendingFlushes = 0
        hasSpokenAudio = false
        scheduledBuffers = 0
        playbackStarted = false
        queuedFrames = 0
        player.stop()
        generation = UUID()
        dropping = socket != nil
        do {
            try connectIfNeeded()
            if dropping { enqueue(["type": "Clear"]) }
        } catch {
            fail(error)
        }
    }

    func speak(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAvailable, !text.isEmpty else { return }
        warm()
        hasSpokenAudio = true
        pendingFlushes += 1
        onSpeakingChanged?(true)
        enqueue(["type": "Speak", "text": text])
        enqueue(["type": "Flush"])
    }

    func finishResponse() {
        responseFinished = true
        settleIfFinished()
    }

    func stop() {
        generation = UUID()
        responseFinished = true
        pendingFlushes = 0
        scheduledBuffers = 0
        hasSpokenAudio = false
        dropping = false
        playbackStarted = false
        queuedFrames = 0
        sendTask?.cancel()
        sendTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        player.stop()
        engine.stop()
        onSpeakingChanged?(false)
    }

    private func connectIfNeeded() throws {
        if socket != nil { return }
        guard var components = URLComponents(string: "wss://api.deepgram.com/v1/speak") else {
            throw DeepgramSpeechError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: Self.model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(Self.sampleRate))),
        ]
        guard let url = components.url else { throw DeepgramSpeechError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        receiveTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard self.socket === socket else { return }
                    self.receive(message)
                }
            } catch {
                guard !Task.isCancelled, self.socket === socket else { return }
                self.fail(error)
            }
        }
    }

    private func enqueue(_ object: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let message = String(data: data, encoding: .utf8) else { return }
        let previous = sendTask
        let id = generation
        sendTask = Task { [weak self] in
            _ = await previous?.result
            guard let self, !Task.isCancelled, self.generation == id, let socket = self.socket else { return }
            do { try await socket.send(.string(message)) }
            catch {
                guard self.generation == id else { return }
                self.fail(error)
            }
        }
    }

    private func receive(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            guard !dropping, !data.isEmpty else { return }
            schedule(data)
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { return }
            switch type {
            case "Cleared":
                dropping = false
            case "Flushed":
                pendingFlushes = max(0, pendingFlushes - 1)
                startPlaybackIfReady()
                settleIfFinished()
            case "Error":
                fail(DeepgramSpeechError.audio)
            default:
                break
            }
        @unknown default:
            break
        }
    }

    private func schedule(_ data: Data) {
        let id = generation
        let byteCount = data.count - data.count % MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }
        let frames = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        buffer.frameLength = frames
        data.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { memcpy(destination, source, byteCount) }
        }
        do {
            if !engine.isRunning { try engine.start() }
            scheduledBuffers += 1
            if !playbackStarted { queuedFrames += frames }
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id else { return }
                    self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                    self.settleIfFinished()
                }
            }
            startPlaybackIfReady()
        } catch {
            fail(error)
        }
    }

    private func startPlaybackIfReady() {
        guard scheduledBuffers > 0 else { return }
        if playbackStarted {
            if !player.isPlaying { player.play() }
            return
        }
        let bufferedSeconds = Double(queuedFrames) / Self.sampleRate
        guard bufferedSeconds >= Self.prebufferSeconds || responseFinished && pendingFlushes == 0 else { return }
        playbackStarted = true
        if !player.isPlaying { player.play() }
    }

    private func settleIfFinished() {
        guard responseFinished, pendingFlushes == 0, scheduledBuffers == 0 else { return }
        onSpeakingChanged?(false)
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.closeIdleConnection()
        }
    }

    private func closeIdleConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        engine.stop()
    }

    private func fail(_ error: Error) {
        let shouldReport = hasSpokenAudio
        stop()
        if shouldReport { onFailure?("Deepgram voice unavailable: \(error.localizedDescription)") }
    }
}
