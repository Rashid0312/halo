// Streaming Deepgram Aura-2 TTS over one websocket. Text goes in sentence by
// sentence (Speak + Flush), raw PCM16 @ 24 kHz comes back in chunks within
// ~200 ms. warm() opens the socket early (e.g. when push-to-talk starts) so
// the ~500 ms connect overlaps with the user still talking.
import WebSocket from "ws";
import { log } from "../log.js";
import { getKey } from "../keys.js";

export const TTS_SAMPLE_RATE = 24000;
const IDLE_CLOSE_MS = 60000;

export class TtsStream {
  /**
   * @param {{ model: () => string, onAudio: (pcm: Buffer) => void, onFlushed?: () => void }} opts
   */
  constructor(opts) {
    this.opts = opts;
    this.ws = null;
    this.ready = null; // Promise<WebSocket>
    this.queue = []; // messages sent before the socket opened
    this.dropping = false; // after clear(): ignore audio until "Cleared"
    this.idleTimer = null;
  }

  url() {
    const p = new URLSearchParams({ model: this.opts.model(), encoding: "linear16", sample_rate: String(TTS_SAMPLE_RATE) });
    return `wss://api.deepgram.com/v1/speak?${p}`;
  }

  /** Open (or reuse) the socket. */
  warm() {
    if (this.ws && this.ws.readyState <= WebSocket.OPEN) return this.ready;
    const apiKey = getKey("deepgram");
    if (!apiKey) {
      log.error("[tts] no Deepgram key yet");
      return Promise.resolve(null);
    }
    const ws = new WebSocket(this.url(), { headers: { Authorization: `Token ${apiKey}` } });
    this.ws = ws;
    this.ready = new Promise((resolve) => {
      ws.on("open", () => {
        for (const m of this.queue.splice(0)) ws.send(m);
        resolve(ws);
      });
      ws.on("error", (err) => {
        log.error(`[tts] ${err.message}`);
        resolve(null);
      });
    });
    ws.on("message", (data, isBinary) => {
      if (isBinary) {
        if (!this.dropping) this.opts.onAudio(Buffer.from(data));
        return;
      }
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (msg.type === "Cleared") this.dropping = false;
      else if (msg.type === "Flushed") this.opts.onFlushed?.();
      else if (msg.type === "Warning" || msg.type === "Error") log.warn(`[tts] ${msg.type}: ${msg.description ?? JSON.stringify(msg)}`);
    });
    ws.on("unexpected-response", (_req, res) => log.error(`[tts] HTTP ${res.statusCode} ${res.headers["dg-error"] ?? ""}`));
    ws.on("close", () => {
      if (this.ws === ws) this.ws = null;
    });
    this.touch();
    return this.ready;
  }

  send(obj) {
    const m = JSON.stringify(obj);
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(m);
    else {
      this.queue.push(m);
      this.warm();
    }
    this.touch();
  }

  /** Speak one sentence; audio starts streaming back right away. */
  speak(text) {
    this.send({ type: "Speak", text });
    this.send({ type: "Flush" });
  }

  /** Interrupt: drop queued text and any audio still in flight. */
  clear() {
    this.queue = this.queue.filter((m) => !m.includes('"Speak"') && !m.includes('"Flush"'));
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.dropping = true;
      this.ws.send(JSON.stringify({ type: "Clear" }));
    }
  }

  /** Voice changed: reconnect with the new model next time. */
  reset() {
    this.close();
  }

  close() {
    clearTimeout(this.idleTimer);
    this.queue = [];
    const ws = this.ws;
    this.ws = null;
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "Close" }));
    setTimeout(() => ws?.terminate(), 500);
  }

  touch() {
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.close(), IDLE_CLOSE_MS);
  }
}
