// "Hey Halo" + only-my-voice, all on the Mac.
//
//   mic (16 kHz, always on while enabled) ─► ring buffer (3 s)
//     ├─ keyword spotter hears "HEY HALO"
//     │    └─ voice check on the trigger (~1.5 s) ── not you ─► ignored (log only)
//     │         └─ you ─► voice.startListening({ via: "wake" })
//     │              VAD: request ends after 0.9 s of silence (no speech in 4 s → cancel, cap 15 s)
//     │              └─ voice check on trigger + request ── not you ─► discarded
//     │                   └─ you ─► voice.finishListening() → brain; learn the voice
//     └─ follow-up: for 6 s after Halo stops talking, speech that matches your
//        voice is a new request (no "Hey Halo" needed). The first second is
//        voice-checked on the Mac before Deepgram hears anything.
//
// Nothing is sent to Deepgram until both checks pass the trigger stage, and no
// audio is written to disk. Paused while Halo speaks (no echo cancellation on
// the mic-only stream) and while the 🎤 button is in use.
import { createKeywordSpotter, createVad, downsample, modelsReady, pcm16ToFloat, rms, SAMPLE_RATE } from "./ondevice.js";
import { enrollPrompt, Voiceprint } from "./voiceprint.js";
import { store } from "./store.js";
import { log } from "./log.js";

const RING_SEC = 3;
const TRIGGER_SEC = 1.5; // audio before the keyword used for the trigger voice check
const NO_SPEECH_MS = 4000;
const MAX_REQUEST_MS = 15000;
const END_SILENCE_SEC = 0.9;
const MIN_FOLLOWUP_SEC = 0.8; // shorter follow-up speech is ignored (coughs, "mm")
const FOLLOWUP_CHECK_SEC = 1.0; // follow-up speech voice-checked locally before Deepgram hears it

export class WakeService {
  /**
   * @param {import("./gateway.js").Gateway} gateway
   * @param {import("./audio.js").AudioService} audio
   * @param {import("./speech.js").SpeechService} speech
   * @param {import("./voice.js").VoiceService} voice
   */
  constructor(gateway, audio, speech, voice) {
    this.gateway = gateway;
    this.audio = audio;
    this.speech = speech;
    this.voice = voice;
    this.listeners = new Set();
    this._mode = "off";
    this.voiceprint = new Voiceprint();
    this.available = modelsReady();
    this.running = false;
    this.mode = "off"; // off | waiting | request | followup | enroll
    this.ring = new Float32Array(RING_SEC * SAMPLE_RATE);
    this.ringPos = 0;
    this.ringFilled = 0;
    this.request = null; // { chunks: Float32Array[], trigger, startedAt, spoke, timers }
    this.levelAt = 0;
  }

  prefs() {
    return store.get("wake");
  }

  /** off | waiting | request | followup | enroll — changes notify listeners and the UI. */
  get mode() {
    return this._mode;
  }

  set mode(m) {
    if (m === this._mode) return;
    this._mode = m;
    for (const cb of this.listeners ?? []) cb(m);
    if (m === "followup" || m === "waiting") this.broadcast();
  }

  /** @param {(mode: string) => void} cb */
  onChange(cb) {
    this.listeners.add(cb);
  }

  async register() {
    this.gateway.handleAll({
      "halo:wakeState": () => this.snapshot(),
      "halo:setWake": async (on) => {
        store.set("wake", { ...this.prefs(), enabled: Boolean(on) });
        await this.sync();
        return this.snapshot();
      },
      "halo:enrollStart": () => this.startEnroll(),
      "halo:enrollCancel": () => this.cancelEnroll(),
      "halo:voiceDelete": async () => {
        await this.voiceprint.delete();
        await this.sync();
        return this.snapshot();
      },
    });
    if (!this.available) {
      log.warn('[wake] models missing — run "npm run models" to enable "Hey Halo"');
      return;
    }
    await this.voiceprint.load();
    this.unsubAudio = this.audio.onChunk((chunk) => this.onChunk(chunk));
    this.voice.onStateChange((state, prev) => this.onVoiceState(state, prev));
    await this.sync();
  }

  snapshot() {
    return {
      available: this.available,
      enrolled: this.voiceprint.enrolled,
      enabled: Boolean(this.prefs().enabled),
      listening: this.running && this.mode !== "enroll",
      mode: this.mode,
    };
  }

  broadcast() {
    this.gateway.broadcast("halo:wake", this.snapshot(), { to: ["panel", "pill"] });
  }

  /** Start or stop always-on listening to match settings + enrollment. */
  async sync() {
    const want = this.available && this.prefs().enabled && this.voiceprint.enrolled;
    if (want && !this.running) await this.start();
    else if (!want && this.running && this.mode !== "enroll") await this.stop();
    this.broadcast();
  }

  async start() {
    if (!this.available) return;
    this.kws ??= createKeywordSpotter();
    this.kwsStream = this.kws.createStream();
    this.vad = createVad({ minSilence: END_SILENCE_SEC });
    this.speech.setWakeMode(true);
    try {
      await this.audio.start();
    } catch (err) {
      log.error(`[wake] microphone failed: ${err.message}`);
      return;
    }
    this.running = true;
    if (this.mode === "off") this.mode = "waiting";
    log.info('[wake] listening for "Hey Halo" (on-device)');
  }

  /** The mic dropped (sleep, unplugged headset) or the Mac woke up: get listening again. */
  async restartMic(reason) {
    if (!this.running || this.restarting) return;
    this.restarting = true;
    log.info(`[wake] restarting the mic (${reason})`);
    try {
      this.endRequest();
      if (this.mode !== "enroll") this.mode = "waiting";
      await this.audio.stop();
      await new Promise((r) => setTimeout(r, 1000));
      await this.audio.start();
    } catch (err) {
      log.warn(`[wake] mic restart failed: ${err.message} — retrying in 10 s`);
      setTimeout(() => this.restartMic("retry"), 10000);
    } finally {
      this.restarting = false;
    }
  }

  async stop() {
    this.endRequest();
    this.running = false;
    this.mode = "off";
    this.speech.setWakeMode(false);
    await this.audio.stop();
    log.info("[wake] stopped");
  }

  // ── audio ────────────────────────────────────────────────────────────
  onChunk(chunk) {
    if (!this.running || chunk.source !== "microphone") return;
    try {
      this.handleChunk(chunk);
    } catch (err) {
      // Never let one bad chunk take down the audio callback.
      if (!this.chunkErrorLogged) log.error(`[wake] ${err.stack ?? err}`);
      this.chunkErrorLogged = true;
    }
  }

  handleChunk(chunk) {
    this.chunkCount = (this.chunkCount ?? 0) + 1;
    // Test hook (with HALO_FAKE_MIC): HALO_FAKE_WAKE_AT="25.9,41.2" simulates the
    // keyword spotter firing at those mic times, to test voice checks on their own.
    if (process.env.HALO_FAKE_WAKE_AT && this.mode === "waiting") {
      this.fakeWakes ??= process.env.HALO_FAKE_WAKE_AT.split(",").map(Number);
      if (this.fakeWakes.length && this.chunkCount * 0.032 >= this.fakeWakes[0]) {
        this.fakeWakes.shift();
        this.onKeyword();
      }
    }
    const factor = Math.round(chunk.sampleRate / SAMPLE_RATE) || 1;
    const x = downsample(pcm16ToFloat(chunk.data), factor);
    this.pushRing(x);
    this.sendLevel(x);
    switch (this.mode) {
      case "waiting":
        // Paused while Halo talks (her voice would echo into the mic) or is already
        // listening. Stays on while a permission card waits: "Hey Halo, yes".
        if (this.voice.state === "speaking" || this.voice.state === "listening") return;
        this.spot(x);
        break;
      case "request":
        this.feedRequest(x);
        break;
      case "followup":
        this.feedFollowUp(x);
        break;
      case "enroll":
        this.feedEnroll(x);
        break;
    }
  }

  pushRing(x) {
    for (let i = 0; i < x.length; i++) {
      this.ring[this.ringPos] = x[i];
      this.ringPos = (this.ringPos + 1) % this.ring.length;
    }
    this.ringFilled = Math.min(this.ring.length, this.ringFilled + x.length);
  }

  /** Last `sec` seconds of mic audio. */
  recent(sec) {
    const n = Math.min(this.ringFilled, Math.round(sec * SAMPLE_RATE));
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = this.ring[(this.ringPos - n + i + this.ring.length) % this.ring.length];
    return out;
  }

  sendLevel(x) {
    if (this.mode !== "enroll") return;
    const now = Date.now();
    if (now - this.levelAt < 60) return;
    this.levelAt = now;
    this.gateway.broadcast("halo:enroll", { level: Math.min(1, rms(x) * 6) }, { to: ["panel"] });
  }

  // ── stage 1: keyword + trigger voice check ───────────────────────────
  spot(x) {
    this.kwsStream.acceptWaveform({ sampleRate: SAMPLE_RATE, samples: x });
    while (this.kws.isReady(this.kwsStream)) {
      this.kws.decode(this.kwsStream);
      if (this.kws.getResult(this.kwsStream).keyword) {
        this.kws.reset(this.kwsStream);
        this.onKeyword();
      }
    }
  }

  onKeyword() {
    log.debug(`[wake] keyword at mic t=${((this.chunkCount ?? 0) * 0.032).toFixed(1)}s`);
    const trigger = this.recent(TRIGGER_SEC);
    const t0 = performance.now();
    const v = this.voiceprint.verify(trigger, "trigger");
    const ms = (performance.now() - t0).toFixed(0);
    if (!v.ok) {
      log.info(`[wake] heard "hey halo" — voice score ${v.score.toFixed(2)} → not you, ignored (${ms}ms)`);
      return;
    }
    log.info(`[wake] heard "hey halo" — voice score ${v.score.toFixed(2)} → you (${ms}ms)`);
    this.beginRequest(trigger, "wake");
  }

  // ── stage 2: the request ─────────────────────────────────────────────
  beginRequest(prefix, via) {
    this.mode = "request";
    this.vad.reset();
    this.request = { chunks: [prefix], via, startedAt: Date.now(), spoke: via === "followup" };
    this.request.noSpeech = setTimeout(() => {
      if (this.request && !this.request.spoke) this.abortRequest("no speech");
    }, NO_SPEECH_MS);
    this.request.cap = setTimeout(() => this.completeRequest(), MAX_REQUEST_MS);
    this.voice.startListening({ via });
  }

  feedRequest(x) {
    const r = this.request;
    if (!r) return;
    r.chunks.push(x);
    for (let i = 0; i + 512 <= x.length; i += 512) this.vad.acceptWaveform(x.subarray(i, i + 512));
    if (this.vad.isDetected()) r.spoke = true;
    // A finished speech segment = the user paused for END_SILENCE_SEC.
    if (r.spoke && !this.vad.isEmpty()) {
      while (!this.vad.isEmpty()) this.vad.pop();
      this.completeRequest();
    }
  }

  async completeRequest() {
    const r = this.request;
    if (!r) return;
    this.clearTimers(r);
    this.request = null;
    this.mode = this.running ? "waiting" : "off";
    const audio = concat(r.chunks);
    if (r.via === "followup" && audio.length < MIN_FOLLOWUP_SEC * SAMPLE_RATE) {
      log.info("[wake] follow-up too short, ignored");
      this.voice.cancelListening();
      return;
    }
    const v = this.voiceprint.verify(audio, "request");
    if (!v.ok) {
      log.info(`[wake] request voice score ${v.score.toFixed(2)} → not you, discarded`);
      this.voice.cancelListening();
      return;
    }
    log.info(`[wake] request voice score ${v.score.toFixed(2)} → you (${(audio.length / SAMPLE_RATE).toFixed(1)}s)`);
    await this.voice.finishListening();
    this.voiceprint.learn(v.vec, v.score).catch((err) => log.warn(`[voiceprint] ${err.message}`));
  }

  abortRequest(reason) {
    const r = this.request;
    if (!r) return;
    this.clearTimers(r);
    this.request = null;
    this.mode = this.running ? "waiting" : "off";
    log.info(`[wake] request cancelled (${reason})`);
    this.voice.cancelListening();
  }

  endRequest() {
    if (this.request) this.clearTimers(this.request);
    this.request = null;
    clearTimeout(this.followUpTimer);
  }

  clearTimers(r) {
    clearTimeout(r.noSpeech);
    clearTimeout(r.cap);
  }

  // ── follow-up window ─────────────────────────────────────────────────
  onVoiceState(state, prev) {
    if (!this.running || this.mode === "enroll") return;
    // The request was finished or cancelled elsewhere (🎤 button, typing): stand down.
    if (this.mode === "request" && state !== "listening") {
      this.endRequest();
      this.mode = "waiting";
    }
    if (prev === "speaking" && state === "idle" && this.mode === "waiting") this.openFollowUp();
  }

  openFollowUp() {
    const ms = this.prefs().followUpMs ?? 6000;
    if (!ms) return;
    this.mode = "followup";
    this.followUpSpeech = null;
    this.vad.reset();
    this.followUpTimer = setTimeout(() => {
      if (this.mode === "followup") this.mode = "waiting";
    }, ms);
    this.broadcast();
  }

  feedFollowUp(x) {
    for (let i = 0; i + 512 <= x.length; i += 512) this.vad.acceptWaveform(x.subarray(i, i + 512));
    const speaking = this.vad.isDetected();
    while (!this.vad.isEmpty()) this.vad.pop();
    if (!this.followUpSpeech) {
      if (!speaking) return;
      // Speech started: collect ~1 s and check the voice before opening Deepgram.
      this.followUpSpeech = { samples: Math.round(0.3 * SAMPLE_RATE) }; // VAD lags ~0.3 s
      clearTimeout(this.followUpTimer);
    }
    this.followUpSpeech.samples += x.length;
    if (!speaking && this.followUpSpeech.samples < FOLLOWUP_CHECK_SEC * SAMPLE_RATE) {
      // Too short to be a request (cough, "mm"): keep waiting in the window.
      this.followUpSpeech = null;
      this.followUpTimer = setTimeout(() => this.mode === "followup" && (this.mode = "waiting"), 2000);
      return;
    }
    if (this.followUpSpeech.samples < FOLLOWUP_CHECK_SEC * SAMPLE_RATE) return;
    const heard = this.recent(this.followUpSpeech.samples / SAMPLE_RATE);
    this.followUpSpeech = null;
    const v = this.voiceprint.verify(heard, "trigger");
    if (!v.ok) {
      log.info(`[wake] follow-up voice score ${v.score.toFixed(2)} → not you, ignored`);
      this.mode = "waiting";
      return;
    }
    log.info(`[wake] follow-up voice score ${v.score.toFixed(2)} → you`);
    // Deepgram gets the buffered speech (speech.js pre-roll) so no words are lost.
    this.beginRequest(heard, "followup");
  }

  // ── explicit enrollment ──────────────────────────────────────────────
  async startEnroll() {
    if (!this.available) throw Object.assign(new Error('Voice models missing — run "npm run models"'), { code: "PROCEDURAL" });
    // Already recording (double click, second window…): keep the progress.
    if (this.mode === "enroll" && this.voiceprint.enrolling) {
      const count = this.voiceprint.enrolling.length;
      return { count, needed: 8, prompt: enrollPrompt(count) };
    }
    this.endRequest();
    // Enrollment owns the mic: drop any open listening so setup speech is never sent anywhere.
    await this.voice.cancelListening();
    this.voice.blocked = true;
    if (!this.running) await this.start();
    this.mode = "enroll";
    // 0.6 s pause ends a clip; sentences can run up to 10 s.
    this.enrollVad = createVad({ minSilence: 0.6, maxSpeech: 10 });
    const state = this.voiceprint.startEnroll();
    log.info("[wake] enrollment started");
    this.broadcast();
    return state;
  }

  feedEnroll(x) {
    for (let i = 0; i + 512 <= x.length; i += 512) this.enrollVad.acceptWaveform(x.subarray(i, i + 512));
    const segs = [];
    while (!this.enrollVad.isEmpty()) {
      segs.push(Float32Array.from(this.enrollVad.front(false).samples));
      this.enrollVad.pop();
    }
    if (segs.length) log.debug(`[wake] enroll: ${segs.length} speech segment(s), ${segs.map((g) => (g.length / SAMPLE_RATE).toFixed(2) + "s").join(",")}`);
    // One clip at a time, in order (embedding + Keychain save are async).
    for (const seg of segs) this.enrollQueue = (this.enrollQueue ?? Promise.resolve()).then(() => this.enrollClip(seg));
  }

  async enrollClip(seg) {
    if (this.mode !== "enroll") return;
    const res = await this.voiceprint.addEnrollClip(seg);
    this.gateway.broadcast("halo:enroll", res, { to: ["panel"] });
    if (res.done) {
      this.voice.blocked = false;
      this.mode = "waiting";
      store.set("wake", { ...this.prefs(), enabled: true });
      log.info('[wake] enrollment complete — "Hey Halo" is on');
      await this.sync();
    }
  }

  async cancelEnroll() {
    this.voiceprint.cancelEnroll();
    this.voice.blocked = false;
    this.mode = "waiting";
    await this.sync();
    if (!this.voiceprint.enrolled && this.running) await this.stop();
    this.broadcast();
  }
}

function concat(parts) {
  const out = new Float32Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}
