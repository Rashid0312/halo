// Transcription session: audio capture → Deepgram (one stream per source) →
// `transcript` frames. Started automatically when a session goes active,
// so the mic is ready as soon as Mercy starts listening.
import { DeepgramStream } from "./stt/deepgram.js";
import { log } from "./log.js";
import { getKey } from "./keys.js";

// Sources are already separated, so role comes from the stream, not diarization.
const STREAMS = {
  microphone: { role: "user", source: "mic", streamId: "user" },
};

// ~2.2 s of 512-sample chunks at 16 kHz: covers the words spoken while a
// follow-up is voice-checked locally (1.5 s + VAD lag) before Deepgram hears it.
const PREROLL_CHUNKS = 70;

export class SpeechService {
  /**
   * @param {import("./gateway.js").Gateway} gateway
   * @param {import("./realtime.js").Realtime} realtime
   * @param {import("./audio.js").AudioService} audio
   * @param {import("./session.js").SessionService} session
   */
  constructor(gateway, realtime, audio, session) {
    this.gateway = gateway;
    this.realtime = realtime;
    this.audio = audio;
    this.session = session;
    this.state = null; // speech session snapshot
    this.streams = new Map();
    // The mic is only captured while listening is open
    // (start ≈ 65 ms, stop < 10 ms); the Deepgram sockets stay connected.
    this.open = false;
    this.audioOp = Promise.resolve(); // serializes capture start/stop
    // Wake mode ("Hey Mercy"): WakeService keeps the mic running at 16 kHz;
    // push-to-talk only gates what reaches Deepgram, with a short lead-in so
    // the first word after "Hey Mercy" isn't clipped.
    this.wakeMode = false;
    this.preroll = [];
  }

  setWakeMode(on) {
    this.wakeMode = on;
    this.preroll = [];
  }

  /** Flush the mic transcript right away (push-to-talk released). */
  finalize(source = "microphone") {
    return this.streams.get(source)?.finalize() ?? Promise.resolve();
  }

  /** Mic audio still queued behind a connecting socket (first press after launch). */
  hasBacklog(source = "microphone") {
    return this.streams.get(source)?.hasBacklog() ?? false;
  }

  /** Open/close push-to-talk: starts or stops audio capture. Resolves when done. */
  setOpen(open) {
    this.open = open;
    if (this.wakeMode) {
      if (open) for (const data of this.preroll.splice(0)) this.streams.get("microphone")?.send(data);
      return this.audioOp;
    }
    this.audioOp = this.audioOp
      .then(async () => {
        const capturing = this.audio.status === "capturing";
        if (this.open && this.streams.size && !capturing) await this.audio.start();
        else if (!this.open && capturing) await this.audio.stop();
      })
      .catch((err) => {
        const message = `Microphone failed to start: ${err?.message ?? err}`;
        log.error(`[speech] ${message}`);
        this.realtime.emit({ type: "error", data: { code: "audio", message, turnId: "", retry: null } });
      });
    return this.audioOp;
  }

  snapshot() {
    return this.state;
  }

  setState(patch) {
    this.state = this.state ? { ...this.state, ...patch } : patch;
    this.gateway.broadcast("speech:status:changed", this.state);
  }

  async start() {
    const ctx = this.session.context;
    const sessionId = this.session.sessionId;
    if (!sessionId) throw Object.assign(new Error("no active session"), { code: "PROCEDURAL" });
    if (this.state?.status === "transcribing" || this.state?.status === "starting") return this.state;

    const apiKey = getKey("deepgram");
    const language = ctx?.language ?? "en-US";
    this.setState({ id: sessionId, status: "starting", language, startedAt: null });
    this.realtime.reset();
    this.realtime.setStatus({ state: "connecting" });

    if (process.env.MERCY_FAKE_STT === "1") return this.startFake(sessionId);

    if (!apiKey) {
      const message = "No Deepgram key yet — add it in Mercy (··· → API keys)";
      log.error(`[speech] ${message}`);
      this.setState({ status: "error", error: message });
      this.realtime.setStatus({ state: "disconnected" });
      this.realtime.emit({ type: "error", data: { code: "config", message, turnId: "", retry: null } });
      return this.state;
    }

    // The mic always arrives at 16 kHz (main/audio.js).
    const sampleRates = { microphone: 16000 };
    for (const [name, meta] of Object.entries(STREAMS)) {
      const stream = new DeepgramStream({
        apiKey,
        name,
        sampleRate: sampleRates[name],
        language,
        onResult: (r) => {
          log.debug(`[stt:${meta.role}]${r.final ? " FINAL" : ""}${r.speechFinal ? " ENDPOINT" : ""} ${r.text}`);
          this.realtime.emit({
            type: "transcript",
            data: { role: meta.role, source: meta.source, text: r.text, segment_id: r.segmentId, final: r.final, speech_final: r.speechFinal },
          });
        },
        onState: (state) => {
          this.realtime.setStatus({ state, streamId: meta.streamId });
          this.realtime.emit({ type: "transcription.state", data: { state, stream_id: meta.streamId } });
        },
      });
      stream.connect();
      this.streams.set(name, stream);
    }

    this.unsubAudio = this.audio.onChunk((chunk) => {
      const stream = this.streams.get(chunk.source);
      if (!stream) return;
      if (!this.open) {
        if (this.wakeMode && chunk.source === "microphone") {
          this.preroll.push(chunk.data);
          if (this.preroll.length > PREROLL_CHUNKS) this.preroll.shift();
        }
        return;
      }
      // Native addon reports the true rate per chunk; reconnect if it ever differs.
      if (chunk.sampleRate !== stream.opts.sampleRate) {
        log.warn(`[speech] ${chunk.source} rate ${chunk.sampleRate} != ${stream.opts.sampleRate}`);
        stream.opts.sampleRate = chunk.sampleRate;
        stream.ws?.close();
      }
      stream.send(chunk.data);
    });

    // Listening may already be open (the 🎤 button or "Hey Mercy" started this session).
    if (this.open) this.setOpen(true);
    this.realtime.setStatus({ state: "live" });
    this.setState({ status: "transcribing", startedAt: Date.now() });
    log.info(`[speech] transcribing session ${sessionId}`);
    return this.state;
  }

  /** Dev mode: scripted transcript frames, no audio or network. */
  startFake(sessionId) {
    const lines = [
      ["user", "Hey, what does a 429 status code mean?"],
      ["user", "How would I add retries with backoff for that?"],
    ];
    let i = 0;
    this.fakeTimer = setInterval(() => {
      const [role, text] = lines[i % lines.length];
      const source = "mic";
      const segment_id = `fake-${i++}`;
      const words = text.split(" ");
      const half = words.slice(0, Math.ceil(words.length / 2)).join(" ");
      this.realtime.emit({ type: "transcript", data: { role, source, text: half, segment_id, final: false } });
      setTimeout(
        () => this.realtime.emit({ type: "transcript", data: { role, source, text, segment_id, final: true } }),
        700,
      );
    }, 2500);
    this.realtime.setStatus({ state: "live" });
    this.setState({ status: "transcribing", startedAt: Date.now() });
    log.info(`[speech] FAKE transcribing session ${sessionId}`);
    return this.state;
  }

  async stop({ ended = false } = {}) {
    clearInterval(this.fakeTimer);
    this.unsubAudio?.();
    this.unsubAudio = null;
    for (const s of this.streams.values()) s.close();
    this.streams.clear();
    this.open = false;
    // In wake mode the mic belongs to WakeService and keeps running.
    if (!this.wakeMode) await this.audio.stop();
    if (ended) {
      this.realtime.emit({ type: "session.ended", data: { reason: "user_ended" } });
      this.realtime.setStatus({ state: "closed", reason: "session_ended" });
    }
    if (this.state) this.setState({ status: "idle" });
  }

  register() {
    this.gateway.handleAll({
      "speech:getStatus": () => this.snapshot(),
      "speech:getRealtimeStatus": () => this.realtime.linkStatus,
      "speech:start": () => this.start(),
      "speech:stop": () => this.stop(),
      "speech:disconnect": () => this.stop(),
      "speech:reconnect": async () => {
        await this.stop();
        return this.start();
      },
      "speech:getVadEnabled": () => false,
      "speech:setVadEnabled": () => null,
    });
    this.session.onChange((snap) => {
      if (snap.status === "active") {
        this.start().catch((err) => log.error(`[speech] start failed: ${err?.message ?? err}`));
      } else if (snap.status === "ending") {
        this.stop({ ended: true }).catch(() => {});
      }
    });
  }
}
