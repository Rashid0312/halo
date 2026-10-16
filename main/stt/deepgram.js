// One Deepgram streaming connection per audio source. Emits
// { text, final, segmentId, speechFinal } per Results message.
import WebSocket from "ws";
import { log } from "../log.js";

const KEEPALIVE_MS = 8000;
const MAX_BACKOFF_MS = 10000;

export class DeepgramStream {
  /**
   * @param {object} opts
   * @param {string} opts.apiKey
   * @param {string} opts.name        log label ("microphone" | "system")
   * @param {number} opts.sampleRate
   * @param {string} [opts.language]  BCP-47, e.g. "en-US"
   * @param {(r: {text: string, final: boolean, speechFinal: boolean, segmentId: string}) => void} opts.onResult
   * @param {(state: "live" | "degraded") => void} [opts.onState]
   * @param {() => string[]} [opts.words]  keyterms to listen for (nova-3; billed as an add-on)
   */
  constructor(opts) {
    this.opts = opts;
    this.ws = null;
    this.closed = false;
    this.attempt = 0;
    this.segment = 0;
    this.pending = [];
  }

  url() {
    const p = new URLSearchParams({
      model: "nova-3",
      encoding: "linear16",
      sample_rate: String(this.opts.sampleRate),
      channels: "1",
      interim_results: "true",
      smart_format: "true",
      punctuate: "true",
      endpointing: "300",
      utterance_end_ms: "1000",
      vad_events: "true",
    });
    if (this.opts.language) p.set("language", this.opts.language);
    // Deepgram: "focus on the most important 20-50 terms", 500 tokens at most.
    for (const w of (this.opts.words?.() ?? []).slice(0, 50)) p.append("keyterm", w);
    return `wss://api.deepgram.com/v1/listen?${p}`;
  }

  connect() {
    if (this.closed) return;
    const ws = new WebSocket(this.url(), { headers: { Authorization: `Token ${this.opts.apiKey}` } });
    this.ws = ws;
    ws.on("open", () => {
      this.attempt = 0;
      log.info(`[deepgram:${this.opts.name}] open @${this.opts.sampleRate}Hz`);
      this.opts.onState?.("live");
      this.sentSec = 0;
      this.heardSec = 0;
      for (const buf of this.pending.splice(0)) this.sendNow(buf);
      this.keepalive = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "KeepAlive" }));
      }, KEEPALIVE_MS);
    });
    ws.on("message", (raw) => this.onMessage(raw));
    ws.on("unexpected-response", (_req, res) => {
      log.error(`[deepgram:${this.opts.name}] HTTP ${res.statusCode} ${res.headers["dg-error"] ?? ""}`);
    });
    ws.on("error", (err) => log.error(`[deepgram:${this.opts.name}] ${err.message}`));
    ws.on("close", (code) => {
      clearInterval(this.keepalive);
      if (this.closed) return;
      this.opts.onState?.("degraded");
      const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempt++);
      log.warn(`[deepgram:${this.opts.name}] closed ${code}, retry in ${delay}ms`);
      this.retry = setTimeout(() => this.connect(), delay);
    });
  }

  onMessage(raw) {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (msg.type !== "Results") return;
    this.heardSec = Math.max(this.heardSec ?? 0, (msg.start ?? 0) + (msg.duration ?? 0));
    if (msg.from_finalize) queueMicrotask(() => this.finalizeDone?.());
    const text = msg.channel?.alternatives?.[0]?.transcript ?? "";
    const final = msg.is_final === true;
    if (!text) return;
    this.opts.onResult({
      text,
      final,
      speechFinal: msg.speech_final === true,
      segmentId: `${this.opts.name}-${this.segment}`,
    });
    if (final) this.segment++;
  }

  /** Reconnect (e.g. at a new sample rate); the close handler reopens the socket. */
  restart() {
    this.ws?.close();
  }

  /** True while audio is waiting for the socket to open. */
  hasBacklog() {
    return this.pending.length > 0;
  }

  /** @param {Buffer} pcm16 */
  send(pcm16) {
    if (this.ws?.readyState === WebSocket.OPEN) this.sendNow(pcm16);
    else if (this.pending.length < 1000) this.pending.push(pcm16); // ~10s buffered while connecting
  }

  sendNow(pcm16) {
    this.ws.send(pcm16);
    this.sentSec = (this.sentSec ?? 0) + this.seconds(pcm16);
  }

  seconds(pcm16) {
    return pcm16.length / 2 / this.opts.sampleRate;
  }

  /**
   * Ask Deepgram to finish transcribing everything sent so far (instead of
   * waiting for its endpoint timer). Resolves when it answers, or after maxMs.
   */
  finalize(maxMs = 600) {
    // Audio still buffered because the socket is connecting: wait for it to open
    // (it flushes the buffer on open), then finalize with more time.
    // Deepgram works through a burst of audio at about real-time speed, and a
    // Finalize sent too early answers with only what it got through so far
    // ("He…"). So after the flush, wait until its results are close to the end
    // of what was sent, then finalize.
    if (this.pending.length && !this.closed) {
      const backlogMs = this.pending.reduce((ms, b) => ms + this.seconds(b) * 1000, 0);
      return new Promise((resolve) => {
        const started = Date.now();
        const poll = setInterval(() => {
          const flushed = this.ws?.readyState === WebSocket.OPEN && !this.pending.length;
          if (flushed && (this.heardSec >= this.sentSec - 1.2 || Date.now() - started > 1500 + backlogMs)) {
            clearInterval(poll);
            this.finalize(1500).then(resolve);
          } else if (Date.now() - started > 4000 + backlogMs) {
            clearInterval(poll);
            resolve();
          }
        }, 20);
      });
    }
    if (this.ws?.readyState !== WebSocket.OPEN) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.finalizeDone = null;
        resolve();
      };
      const timer = setTimeout(done, maxMs);
      this.finalizeDone = done;
      this.ws.send(JSON.stringify({ type: "Finalize" }));
    });
  }

  close() {
    this.closed = true;
    clearTimeout(this.retry);
    clearInterval(this.keepalive);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "CloseStream" }));
      setTimeout(() => this.ws?.terminate(), 1000);
    } else {
      this.ws?.terminate();
    }
  }
}
