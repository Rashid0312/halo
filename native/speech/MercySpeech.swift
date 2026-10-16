// Mercy's on-device speech recognition (Apple SpeechAnalyzer, macOS 26+).
//
// Usage: mercy-speech --locale en-US --rate 16000 [--transcriber speech|dictation]
//
// Protocol with Mercy (main/stt/apple.js):
//   stdin   frames: [1 byte type][4 byte little-endian length][payload]
//             "A" — PCM16 mono audio at --rate
//             "F" — finalize: turn everything sent so far into final text
//             "W" — words to listen for (UTF-8, one per line), from the next turn on
//   stdin closes                           — exit
//   stdout  one JSON object per line:
//           {"type":"state","state":"downloading"} — fetching the language model
//           {"type":"ready"}                       — send audio
//           {"type":"result","text":…,"final":…}   — volatile (live) or final text
//           {"type":"finalized"}                   — answer to "F"
//           {"type":"error","message":…}           — then exits with status 1
@preconcurrency import AVFoundation
import Foundation
import Speech

func emit(_ obj: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func fail(_ message: String) -> Never {
  emit(["type": "error", "message": message])
  exit(1)
}

func arg(_ name: String, _ fallback: String) -> String {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
  return args[i + 1]
}

enum Command {
  case audio(Data)
  case finalize
  case words([String])
}

/// Reads stdin frames on a background thread.
func readCommands() -> AsyncStream<Command> {
  AsyncStream { continuation in
    Thread {
      let input = FileHandle.standardInput
      func read(_ count: Int) -> Data? {
        var out = Data()
        while out.count < count {
          let chunk = input.readData(ofLength: count - out.count)
          if chunk.isEmpty { return nil }
          out += chunk
        }
        return out
      }
      while let header = read(5) {
        let type = header[header.startIndex]
        let length = header.dropFirst().enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard let payload = length > 0 ? read(length) : Data() else { break }
        switch type {
        case UInt8(ascii: "A"): continuation.yield(.audio(payload))
        case UInt8(ascii: "F"): continuation.yield(.finalize)
        case UInt8(ascii: "W"):
          let words = String(decoding: payload, as: UTF8.self).split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
          continuation.yield(.words(words))
        default: break
        }
      }
      continuation.finish()
    }.start()
  }
}

/// Volatile text not yet replaced by a final result.
actor Pending {
  var volatile = false
  func set(_ on: Bool) { volatile = on }
}

/// One analyzer per turn: after a mid-stream finalize, an analyzer keeps going
/// but transcribes the next turn noticeably worse (",, What does…").
@available(macOS 26.0, *)
final class Turn {
  let analyzer: SpeechAnalyzer
  let feed: AsyncStream<AnalyzerInput>.Continuation
  let pending = Pending()
  var started = false // audio has been fed

  init(locale: Locale, format: AVAudioFormat, dictation: Bool, words: [String]) async throws {
    let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.feed = feed
    let pending = pending
    func report(_ text: AttributedString, _ isFinal: Bool) async {
      let text = String(text.characters).trimmingCharacters(in: .whitespaces)
      await pending.set(!isFinal && !text.isEmpty)
      if !text.isEmpty { emit(["type": "result", "text": text, "final": isFinal]) }
    }
    if dictation {
      let transcriber = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults], attributeOptions: [])
      analyzer = SpeechAnalyzer(modules: [transcriber])
      Task {
        do {
          for try await result in transcriber.results { await report(result.text, result.isFinal) }
        } catch is CancellationError {
          // a turn replaced before it heard anything (new word hints)
        } catch {
          fail("recognition failed: \(error.localizedDescription)")
        }
      }
    } else {
      let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
      analyzer = SpeechAnalyzer(modules: [transcriber])
      Task {
        do {
          for try await result in transcriber.results { await report(result.text, result.isFinal) }
        } catch is CancellationError {
          // a turn replaced before it heard anything (new word hints)
        } catch {
          fail("recognition failed: \(error.localizedDescription)")
        }
      }
    }
    // Words to listen for (names, apps…): a hint, never required.
    if !words.isEmpty {
      let context = AnalysisContext()
      context.contextualStrings[.general] = words
      do {
        try await analyzer.setContext(context)
      } catch {
        FileHandle.standardError.write(Data("word hints not applied: \(error.localizedDescription)\n".utf8))
      }
    }
    try await analyzer.prepareToAnalyze(in: format)
    try await analyzer.start(inputSequence: inputs)
  }

  /// Final text for everything fed so far, then shut down.
  func finish() async {
    feed.finish()
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    // The final result can trail the analyzer by a moment.
    for _ in 0..<25 {
      guard await pending.volatile else { break }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}

@available(macOS 26.0, *)
func run() async {
  let rate = Double(arg("--rate", "16000")) ?? 16000
  let dictation = arg("--transcriber", "speech") == "dictation"
  let wanted = Locale(identifier: arg("--locale", "en-US"))
  let locale: Locale
  let probe: any SpeechModule
  if dictation {
    guard let l = await DictationTranscriber.supportedLocale(equivalentTo: wanted) else { fail("language not supported on device") }
    locale = l
    probe = DictationTranscriber(locale: l, preset: .progressiveShortDictation)
  } else {
    guard SpeechTranscriber.isAvailable else { fail("SpeechTranscriber is not available on this Mac") }
    guard let l = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else { fail("language not supported on device") }
    locale = l
    probe = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
  }

  do {
    if await AssetInventory.status(forModules: [probe]) != .installed,
      let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
    {
      emit(["type": "state", "state": "downloading"])
      try await request.downloadAndInstall()
    }
  } catch {
    fail("could not install the speech model: \(error.localizedDescription)")
  }

  let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
  guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe], considering: inputFormat) else {
    fail("no audio format for the speech model")
  }
  let converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)

  var words: [String] = []
  func newTurn() async -> Turn {
    do {
      return try await Turn(locale: locale, format: format, dictation: dictation, words: words)
    } catch {
      fail("could not start: \(error.localizedDescription)")
    }
  }
  var turn = await newTurn()

  emit(["type": "ready"])
  for await command in readCommands() {
    switch command {
    case .audio(let data):
      let frames = AVAudioFrameCount(data.count / 2)
      guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { continue }
      pcm.frameLength = frames
      data.withUnsafeBytes { raw in
        pcm.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
      }
      var buffer = pcm
      if let converter {
        let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / rate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { continue }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
          if given {
            status.pointee = .noDataNow
            return nil
          }
          given = true
          status.pointee = .haveData
          return pcm
        }
        if error != nil { continue }
        buffer = out
      }
      turn.started = true
      turn.feed.yield(AnalyzerInput(buffer: buffer))
    case .finalize:
      await turn.finish()
      emit(["type": "finalized"])
      turn = await newTurn()
    case .words(let list):
      words = list
      // Nothing heard yet in this turn: start it again with the hints.
      if await !turn.pending.volatile, !turn.started {
        await turn.analyzer.cancelAndFinishNow()
        turn = await newTurn()
      }
    }
  }
  await turn.analyzer.cancelAndFinishNow()
  exit(0)
}

if #available(macOS 26.0, *) {
  Task { await run() }
  dispatchMain()
} else {
  fail("needs macOS 26 or later")
}
