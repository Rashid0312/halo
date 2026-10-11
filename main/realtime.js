// Event bus for live frames (transcripts, answer tokens, tool progress):
// speech.js and brain.js emit, the panel and voice.js listen.

export class Realtime {
  /** @param {import("./gateway.js").Gateway} gateway */
  constructor(gateway) {
    this.gateway = gateway;
    this.seq = 0;
    this.linkStatus = null;
    this.frameListeners = new Set();
  }

  /** @param {{ type: string, data: object }} frame */
  emit(frame) {
    const out = { ...frame, seq: ++this.seq };
    this.gateway.broadcast("speech:realtime-frame:received", JSON.stringify(out));
    for (const cb of this.frameListeners) cb(out);
    return out.seq;
  }

  onFrame(cb) {
    this.frameListeners.add(cb);
    return () => this.frameListeners.delete(cb);
  }

  /** Link-level status (no streamId) or per-stream degraded/live (with streamId). */
  setStatus(status) {
    if (status.streamId === undefined) this.linkStatus = status;
    this.gateway.broadcast("speech:realtime-status:changed", status);
  }

  reset() {
    this.seq = 0;
    this.linkStatus = null;
  }
}
