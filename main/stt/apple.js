// On-device speech recognition through Apple's SpeechAnalyzer (macOS 26+),
// run by a small native helper (native/speech/MercySpeech.swift). Same shape
// as DeepgramStream: emits { text, final, segmentId, speechFinal } per result.
import { spawn } from "node:child_process";
import os from "node:os";
import readline from "node:readline";
import { buildHelper } from "../native.js";
import { log } from "../log.js";

const MAX_BACKOFF_MS = 10000;
const AUDIO = 0x41; // "A"
const FINALIZE = 0x46; // "F"
const WORDS = 0x57; // "W"

/** True when this Mac can run Apple's on-device recognizer (macOS 26 = Darwin 25). */
export function appleSttSupported() {
  return process.platform === "darwin" && Number(os.release().split(".")[0]) >= 25;
}

/** Build (development) or locate (packaged) the helper. Rejects if it can't. */
export function prepareAppleStt() {
  return buildHelper("speech", "MercySpeech.swift", "mercy-speech");
}

function frame(type, payload = Buffer.alloc(0)) {
  const header = Buffer.alloc(5);
  header[0] = type;
  header.writeUInt32LE(payload.length, 1);
  return Buffer.concat([header, payload]);
}

export class AppleStream {
  /**
   * @param {object} opts
   * @param {string} opts.binary      path to mercy-speech
   * @param {string} opts.name        log label ("microphone")
   * @param {number} opts.sampleRate
   * @param {string} [opts.language]  BCP-47, e.g. "en-US"
   * @param {(r: {text: string, final: boolean, speechFinal: boolean, segmentId: string}) => void} opts.onResult
   * @param {(state: "live" | "degraded") => void} [opts.onState]
   * @param {(message: string) => void} [opts.onFatal]  the helper can't run here at all
   * @param {"speech" | "dictation"} [opts.transcriber]  Apple's general model (default) or its dictation model
   * @param {() => string[]} [opts.words]  words to listen for (only the dictation model uses them)
   */
  constructor(opts) {
    this.opts = opts;
    this.child = null;
    this.ready = false;
    this.everReady = false;
    this.closed = false;
    this.attempt = 0;
    this.segment = 0;
    this.pending = [];
    this.finalizeDone = null;
  }

  connect() {
    if (this.closed) return;
    const args = ["--locale", this.opts.language ?? "en-US", "--rate", String(this.opts.sampleRate)];
    if (this.opts.transcriber) args.push("--transcriber", this.opts.transcriber);
    const child = spawn(this.opts.binary, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    this.ready = false;
    let fatal = "";
    child.stdin.on("error", () => {}); // EPIPE when it exits mid-write; "exit" handles it
    child.stderr.on("data", (d) => log.debug(`[apple-stt:${this.opts.name}] ${d.toString().trim()}`));
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return;
      }
      if (msg.type === "ready") {
        this.ready = true;
        this.everReady = true;
        this.attempt = 0;
        log.info(`[apple-stt:${this.opts.name}] ready @${this.opts.sampleRate}Hz`);
        this.opts.onState?.("live");
        const words = this.opts.words?.() ?? [];
        if (words.length) child.stdin.write(frame(WORDS, Buffer.from(words.join("\n"))));
        for (const buf of this.pending.splice(0)) this.sendNow(buf);
      } else if (msg.type === "state" && msg.state === "downloading") {
        log.info(`[apple-stt:${this.opts.name}] downloading the ${this.opts.language ?? "en-US"} speech model…`);
      } else if (msg.type === "result") {
        this.onResult(msg);
      } else if (msg.type === "finalized") {
        this.finalizeDone?.();
      } else if (msg.type === "error") {
        fatal = msg.message;
        log.error(`[apple-stt:${this.opts.name}] ${msg.message}`);
      }
    });
    child.on("error", (err) => log.error(`[apple-stt:${this.opts.name}] ${err.message}`));
    child.on("exit", (code) => {
      if (this.child !== child) return;
      this.child = null;
      this.ready = false;
      this.finalizeDone?.();
      if (this.closed) return;
      // Failed before it was ever ready (old macOS, unsupported language…): retrying won't help.
      if (fatal && !this.everReady) {
        this.closed = true;
        this.opts.onFatal?.(fatal);
        return;
      }
      this.opts.onState?.("degraded");
      const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempt++);
      log.warn(`[apple-stt:${this.opts.name}] helper exited (${code}), restart in ${delay}ms`);
      this.retry = setTimeout(() => this.connect(), delay);
    });
  }

  onResult(msg) {
    if (!msg.text) return;
    this.opts.onResult({
      text: msg.text,
      final: msg.final === true,
      speechFinal: false, // end of turn is decided locally (wake.js VAD / push-to-talk)
      segmentId: `${this.opts.name}-${this.segment}`,
    });
    if (msg.final) this.segment++;
  }

  /** True while audio is waiting for the helper to be ready. */
  hasBacklog() {
    return this.pending.length > 0;
  }

  /** @param {Buffer} pcm16 */
  send(pcm16) {
    if (this.ready) this.sendNow(pcm16);
    else if (this.pending.length < 1000) this.pending.push(pcm16); // ~10s buffered while starting
  }

  sendNow(pcm16) {
    this.child?.stdin.write(frame(AUDIO, pcm16));
  }

  /** Start over at a new sample rate (the mic reported a different one). */
  restart() {
    this.child?.kill();
  }

  /**
   * Turn everything sent so far into final text. Resolves when the helper
   * answers, or after maxMs. Audio still waiting for the helper to start is
   * sent first, so it gets more time.
   */
  finalize(maxMs = 600) {
    if (this.closed) return Promise.resolve();
    const backlogMs = this.pending.reduce((ms, b) => ms + (b.length / 2 / this.opts.sampleRate) * 1000, 0);
    const limit = this.ready ? maxMs : 4000 + backlogMs;
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        if (this.finalizeDone === done) this.finalizeDone = null;
        resolve();
      };
      const timer = setTimeout(done, limit);
      this.finalizeDone = done;
      const send = () => this.child?.stdin.write(frame(FINALIZE));
      if (this.ready) send();
      else {
        // Ask once the backlog has gone out.
        const poll = setInterval(() => {
          if (this.finalizeDone !== done) clearInterval(poll);
          else if (this.ready && !this.pending.length) {
            clearInterval(poll);
            send();
          }
        }, 20);
      }
    });
  }

  close() {
    this.closed = true;
    clearTimeout(this.retry);
    this.finalizeDone?.();
    this.child?.stdin.end(); // the helper exits when stdin closes
    const child = this.child;
    setTimeout(() => child?.kill(), 1000);
  }
}
