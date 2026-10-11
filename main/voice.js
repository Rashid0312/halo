// Push-to-talk + spoken replies.
//
//   "Hey Halo" / 🎤 ──► listening (mic finals collected by the brain; TTS socket warms up)
//   end of speech / 🎤 ──► finalize transcript ──► brain.ask(utterance)
//          ──► turn.token* ──► sentences ──► streaming Aura-2 (websocket)
//          ──► PCM chunks ──► panel (Web Audio) plays them gaplessly
//
// Starting to listen while Halo is talking cuts her off.
// Each sentence is sent as soon as it completes; audio starts ~200 ms later.
import { app } from "electron";
import { spawn } from "node:child_process";
import { TtsStream, TTS_SAMPLE_RATE } from "./tts/stream.js";
import { createVad, modelsReady, pcm16ToFloat } from "./ondevice.js";
import { store } from "./store.js";
import { log } from "./log.js";

// Button / Touch Bar listening ends by itself: after you've spoken, this much
// silence sends the request; saying nothing for NO_SPEECH_MS cancels it.
const END_SILENCE_SEC = 0.9;
const NO_SPEECH_MS = 6000;
const MAX_LISTEN_MS = 30000;

const CUE = { start: "/System/Library/Sounds/Tink.aiff", stop: "/System/Library/Sounds/Pop.aiff" };
export class VoiceService {
  /**
   * @param {import("./gateway.js").Gateway} gateway
   * @param {import("./realtime.js").Realtime} realtime
   * @param {import("./brain.js").Brain} brain
   * @param {import("./session.js").SessionService} session
   * @param {import("./speech.js").SpeechService} speech
   * @param {import("./permissions.js").Permissions} permissions
   */
  constructor(gateway, realtime, brain, session, speech, permissions) {
    this.permissions = permissions;
    this.gateway = gateway;
    this.realtime = realtime;
    this.brain = brain;
    this.session = session;
    this.speech = speech;
    this.state = "idle"; // idle | listening | thinking | speaking | waiting
    this.gen = 0; // bumped on every interrupt; the panel drops audio from older gens
    this.pending = 0; // sentences sent to TTS and not yet flushed back
    this.panelPlaying = false; // reported by the panel's audio player
    this.reply = null; // { turnId, buffer, inCode, saidCode }
    this.listeningVia = null; // "button" | "wake" | "followup" while listening
    this.stateListeners = new Set();
    this.tts = new TtsStream({
      model: () => this.prefs().model,
      onAudio: (pcm) => {
        if (this.askedAt) {
          log.info(`[voice] first audio ${Date.now() - this.askedAt}ms after the question`);
          this.askedAt = 0;
        }
        this.gateway.broadcast("halo:audio", { gen: this.gen, rate: TTS_SAMPLE_RATE, pcm }, { to: ["panel"] });
      },
      onFlushed: () => {
        this.pending = Math.max(0, this.pending - 1);
        this.settle();
      },
    });
  }

  prefs() {
    return store.get("voice");
  }

  register() {
    log.info(`[voice] voice ${this.prefs().model}`);
    this.realtime.onFrame((frame) => this.onFrame(frame));
    this.permissions.onPendingChange((waiting) => {
      if (waiting) {
        this.setState("waiting");
        if (this.prefs().enabled) this.say("I need your okay for this. Say yes or no.");
      } else if (this.state === "waiting") this.setState("thinking");
    });
    this.session.onChange((snap) => {
      if (snap.status !== "active") {
        this.stopSpeaking();
        this.brain.listening = false;
        this.speech.setOpen(false);
        this.setState("idle");
      }
    });
    this.gateway.handleAll({
      "halo:getState": () => ({ state: this.state, voiceEnabled: this.prefs().enabled }),
      "halo:toggleTalk": () => this.toggle(),
      "halo:askText": (text) => this.askText(text),
      "halo:setVoiceEnabled": (on) => this.setEnabled(on),
      "halo:playback": ({ playing, gen } = {}) => {
        if (gen !== this.gen) return;
        this.panelPlaying = Boolean(playing);
        if (this.panelPlaying && this.state !== "listening" && this.state !== "waiting") this.setState("speaking");
        else this.settle();
      },
      "halo:quit": () => app.quit(),
    });
  }

  /** Speak replies on/off (panel tile or menu bar menu); keeps both in sync. */
  setEnabled(on) {
    store.set("voice", { ...this.prefs(), enabled: Boolean(on) });
    if (!on) this.stopSpeaking();
    this.gateway.broadcast("halo:speak", Boolean(on), { to: ["panel"] });
  }

  setState(state) {
    if (this.state === state) return;
    const prev = this.state;
    this.state = state;
    this.gateway.broadcast("halo:state", state, { to: ["panel", "pill"] });
    for (const cb of this.stateListeners) cb(state, prev);
  }

  /** @param {(state: string, prev: string) => void} cb */
  onStateChange(cb) {
    this.stateListeners.add(cb);
  }

  /** After a turn or playback changes: speaking while audio is due, else idle. */
  settle() {
    if (this.state === "listening" || this.state === "waiting") return;
    if (this.panelPlaying || this.pending) {
      if (this.panelPlaying) this.setState("speaking");
    } else if (!this.reply && !this.brain.turn) this.setState("idle");
  }

  unregister() {
    this.stopSpeaking();
    this.tts.close();
  }

  async toggle() {
    if (this.brain.listening) {
      if (this.stopping) return;
      this.stopping = true;
      try {
        await this.finishListening();
      } finally {
        this.stopping = false;
      }
      return;
    }
    this.startListening();
  }

  /** Listening ended (end of speech, or tapped again): stop capture, finalize, then answer. */
  async finishListening() {
    if (!this.brain.listening) return;
    this.stopEndpointing();
    const released = Date.now();
    cue(CUE.stop);
    await this.speech.setOpen(false);
    // Unfinished words? Ask Deepgram for them now instead of waiting on its timer.
    if (this.brain.interim || this.speech.hasBacklog()) await this.speech.finalize();
    const via = this.listeningVia;
    this.listeningVia = null;
    let text = this.brain.stopListening();
    // "Hey Halo, what's the time" → "what's the time"
    if (via === "wake") text = text.replace(/^\s*(?:(?:hey|hi|okay|ok|a)[\s,]+)?(?:halo|hello|hailo|hallo|haylo)\b[\s,.!?]*/i, "").trim();
    // A "yes"/"no" while Halo is waiting for permission answers it.
    if (text && this.permissions.answerByVoice(text)) {
      this.gateway.broadcast("halo:asked", text, { to: ["panel"] });
      this.setState(this.permissions.pending.size ? "waiting" : "thinking");
      return;
    }
    if (text) {
      this.gateway.broadcast("halo:asked", text, { to: ["panel"] });
      this.setState("thinking");
      this.askedAt = released;
      this.brain.ask(text);
    } else {
      log.info("[voice] heard nothing");
      this.setState(this.permissions.pending.size ? "waiting" : "idle");
    }
  }

  /** Wake request that turned out not to be the user (or nothing was said): drop it silently. */
  async cancelListening() {
    if (!this.brain.listening) return;
    this.stopEndpointing();
    this.listeningVia = null;
    await this.speech.setOpen(false);
    this.brain.stopListening();
    this.setState(this.permissions.pending.size ? "waiting" : "idle");
  }

  /** @param {{ via?: "button" | "wake" | "followup" }} [opts] */
  startListening({ via = "button" } = {}) {
    if (this.blocked) {
      log.info("[voice] ignored — voice setup in progress");
      return;
    }
    log.info(`[voice] listening (${via})`);
    this.listeningVia = via;
    this.stopSpeaking();
    if (this.session.status !== "active") this.session.start();
    // Keep the running turn alive if we're only collecting a yes/no.
    this.brain.startListening({ keepTurn: this.permissions.pending.size > 0 });
    this.speech.setOpen(true);
    this.setState("listening");
    cue(CUE.start);
    // Connect TTS while the user is still talking.
    if (this.prefs().enabled) this.tts.warm();
    // "Hey Halo" / follow-ups are ended by wake.js; button + Touch Bar end here.
    if (via === "button") this.startEndpointing();
  }

  /** Watch the mic with the on-device VAD and end listening when the user stops talking. */
  startEndpointing() {
    if (!this.audio || !modelsReady()) return; // no models: tap again to send
    this.stopEndpointing();
    this.endVad ??= createVad({ minSilence: END_SILENCE_SEC, maxSpeech: MAX_LISTEN_MS / 1000 });
    this.endVad.reset();
    const startedAt = Date.now();
    let spoke = false;
    let done = false;
    const end = (why) => {
      if (done) return;
      done = true;
      this.stopEndpointing();
      log.info(`[voice] ${why}`);
      if (why === "end of speech" || why === "listening cap") this.toggle();
      else this.cancelListening();
    };
    this.unsubEndpoint = this.audio.onChunk((chunk) => {
      if (chunk.source !== "microphone") return;
      const x = pcm16ToFloat(chunk.data);
      for (let i = 0; i + 512 <= x.length; i += 512) this.endVad.acceptWaveform(x.subarray(i, i + 512));
      if (this.endVad.isDetected()) spoke = true;
      if (spoke && !this.endVad.isEmpty()) {
        while (!this.endVad.isEmpty()) this.endVad.pop();
        return end("end of speech");
      }
      const ms = Date.now() - startedAt;
      if (!spoke && ms > NO_SPEECH_MS) return end("nothing said — cancelled");
      if (ms > MAX_LISTEN_MS) return end("listening cap");
    });
  }

  stopEndpointing() {
    this.unsubEndpoint?.();
    this.unsubEndpoint = null;
  }

  /** Typed message from the panel: same brain, same tools, same permissions. */
  askText(text) {
    text = String(text ?? "").trim();
    if (!text) return;
    if (this.brain.listening) {
      // Typing while the mic is open: drop the voice capture, the text wins.
      this.brain.listening = false;
      this.speech.setOpen(false);
    }
    this.stopSpeaking();
    if (this.prefs().enabled) this.tts.warm();
    this.gateway.broadcast("halo:asked", text, { to: ["panel"] });
    if (this.permissions.answerByVoice(text)) {
      this.setState(this.permissions.pending.size ? "waiting" : "thinking");
      return;
    }
    this.setState("thinking");
    this.askedAt = Date.now();
    this.brain.ask(text);
  }

  // ── turn tokens → sentences ─────────────────────────────────────────
  onFrame(frame) {
    const { type, data } = frame;
    // Some answers need to be seen, not just heard: open the panel for them.
    if (type === "turn.started") this.answerText = "";
    else if (type === "turn.token") this.answerText = (this.answerText ?? "") + data.delta;
    else if (type === "turn.done" && (!this.prefs().enabled || /```/.test(this.answerText ?? ""))) this.session.showPanel();
    if (type === "turn.started" && this.state !== "listening") this.setState("thinking");
    if ((type === "turn.done" || type === "turn.superseded" || type === "error") && !this.prefs().enabled) {
      queueMicrotask(() => this.settle());
    }
    if (!this.prefs().enabled) return;
    if (type === "turn.started") {
      this.stopSpeaking();
      this.reply = { turnId: data.turn_id, buffer: "", inCode: false, saidCode: false };
    } else if (type === "turn.token" && this.reply?.turnId === data.turn_id) {
      this.reply.buffer += data.delta;
      this.drain(false);
    } else if (type === "turn.done" && this.reply?.turnId === data.turn_id) {
      this.drain(true);
      this.reply = null;
      // brain.turn is cleared right after turn.done is emitted.
      queueMicrotask(() => this.settle());
    } else if (type === "turn.superseded" && this.reply?.turnId === data.turn_id) {
      this.stopSpeaking();
      this.settle();
    } else if (type === "error") {
      queueMicrotask(() => this.settle());
    }
  }

  /** Pull complete lines/sentences out of the buffer; code fences are shown, not read. */
  drain(final) {
    const s = this.reply;
    for (;;) {
      const nl = s.buffer.indexOf("\n");
      if (nl < 0) break;
      const line = s.buffer.slice(0, nl);
      s.buffer = s.buffer.slice(nl + 1);
      this.line(line);
    }
    // Speak finished sentences mid-line instead of waiting for the newline.
    for (let m; !s.inCode && (m = s.buffer.match(/^(.*?[.!?]["')*_]*)\s+(?=\S)/s)); ) {
      this.say(m[1]);
      s.buffer = s.buffer.slice(m[0].length);
    }
    if (final && s.buffer) {
      this.line(s.buffer);
      s.buffer = "";
    }
  }

  line(line) {
    const s = this.reply;
    if (/^\s*```/.test(line)) {
      s.inCode = !s.inCode;
      if (s.inCode && !s.saidCode) {
        s.saidCode = true;
        this.say("I've put the code on screen.");
      }
      return;
    }
    if (!s.inCode) this.say(line);
  }

  say(raw) {
    const text = speakable(raw);
    if (!text) return;
    this.pending++;
    this.tts.speak(text);
  }

  stopSpeaking() {
    this.gen++;
    // Only Clear when something is in flight: audio after a Clear is dropped
    // until Deepgram confirms, which would clip the next sentence otherwise.
    if (this.pending || this.panelPlaying) this.tts.clear();
    this.pending = 0;
    this.panelPlaying = false;
    this.reply = null;
    this.gateway.broadcast("halo:audioStop", { gen: this.gen }, { to: ["panel"] });
  }
}

/** Strip markdown so the voice doesn't read symbols aloud. */
function speakable(s) {
  return s
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_#>]+/g, "")
    .replace(/^\s*(?:[-•]|\d+[.)])\s+/, "")
    .replace(/\s+/g, " ")
    .trim();
}

function cue(file) {
  spawn("afplay", ["-v", "0.4", file]).on("error", () => {});
}
