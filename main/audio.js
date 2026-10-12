// Microphone capture. A hidden window records with getUserMedia (Chromium's
// echo cancellation, noise suppression, auto gain) and an AudioWorklet sends
// 512-sample PCM16 chunks at 16 kHz. Listeners get
//   { source: "microphone", data: Buffer (PCM16 LE mono), sampleRate: 16000 }
import { BrowserWindow, ipcMain, session, systemPreferences } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
import { log } from "./log.js";

const SAMPLE_RATE = 16000;

export class AudioService {
  /**
   * @param {import("./gateway.js").Gateway} gateway
   * @param {import("./windows.js").WindowRegistry} windows
   */
  constructor(gateway, windows) {
    this.gateway = gateway;
    this.windows = windows;
    this.status = "idle";
    this.chunkListeners = new Set();
    this.pending = new Map(); // command id -> resolve
    this.endedListeners = new Set();
  }

  register() {
    ipcMain.on("mic:chunk", (event, buf) => {
      if (this.status !== "capturing" || !this.isMicWindow(event.sender)) return;
      const out = { source: "microphone", data: Buffer.from(buf), sampleRate: SAMPLE_RATE };
      if (!this.firstChunkLogged) {
        this.firstChunkLogged = true;
        log.debug(`[audio] first mic chunk: ${out.data.length} bytes`);
      }
      for (const cb of this.chunkListeners) cb(out);
    });
    ipcMain.on("mic:reply", (event, id, res) => {
      if (this.isMicWindow(event.sender)) this.pending.get(id)?.(res);
    });
    ipcMain.on("mic:status", (event, s) => {
      if (this.isMicWindow(event.sender) && s?.state === "ended") {
        log.warn("[audio] microphone went away (unplugged, sleep, or taken over)");
        this.setStatus("idle");
        for (const cb of this.endedListeners) cb();
      }
    });
    // Only Mercy's own pages may use the mic.
    session.defaultSession.setPermissionRequestHandler((wc, permission, cb) =>
      cb(permission === "media" && wc.getURL().startsWith("file://")),
    );
    session.defaultSession.setPermissionCheckHandler((wc, permission) => permission === "media" && Boolean(wc?.getURL().startsWith("file://")));
  }

  isMicWindow(wc) {
    return BrowserWindow.fromWebContents(wc) === this.windows.first("mic");
  }

  /** @param {(chunk: {source: string, data: Buffer, sampleRate: number}) => void} cb */
  onChunk(cb) {
    this.chunkListeners.add(cb);
    return () => this.chunkListeners.delete(cb);
  }

  /** @param {() => void} cb called when the mic stops by itself */
  onEnded(cb) {
    this.endedListeners.add(cb);
  }

  setStatus(status) {
    this.status = status;
  }

  async micWindow() {
    const existing = this.windows.first("mic");
    if (existing) return existing;
    const win = this.windows.open("mic", {
      show: false,
      width: 1,
      height: 1,
      skipTaskbar: true,
      webPreferences: { backgroundThrottling: false },
    });
    await new Promise((r) => win.webContents.once("did-finish-load", r));
    return win;
  }

  async command(cmd) {
    const win = await this.micWindow();
    const id = crypto.randomUUID();
    const res = await new Promise((resolve) => {
      this.pending.set(id, resolve);
      win.webContents.send("mic:command", { id, cmd });
      setTimeout(() => resolve({ ok: false, error: `mic ${cmd} timed out` }), 10000);
    });
    this.pending.delete(id);
    if (!res.ok) throw new Error(res.error);
    return res.result;
  }

  /** Start the microphone (other sources from older callers are ignored). */
  async start() {
    if (this.status === "capturing" || this.status === "starting") return;
    if (process.env.MERCY_FAKE_MIC) return this.startFake(process.env.MERCY_FAKE_MIC);
    this.setStatus("starting");
    try {
      if (systemPreferences.getMediaAccessStatus("microphone") !== "granted") {
        const ok = await systemPreferences.askForMediaAccess("microphone");
        if (!ok) throw new Error("Microphone access is off — allow Mercy in System Settings → Privacy & Security → Microphone");
      }
      this.firstChunkLogged = false;
      const device = await this.command("start");
      this.setStatus("capturing");
      log.info(`[audio] capturing ${device}`);
    } catch (err) {
      this.setStatus("idle");
      throw err;
    }
  }

  /** Test hook: stream a 16 kHz mono PCM16 file as the microphone, in real time, then silence. */
  startFake(file) {
    const pcm = fs.readFileSync(file);
    const CHUNK = 1024; // bytes = 512 samples = 32 ms
    let pos = 0;
    this.setStatus("capturing");
    log.info(`[audio] FAKE mic from ${file} (${(pcm.length / 32000).toFixed(1)}s)`);
    this.fakeTimer = setInterval(() => {
      const data = pos < pcm.length ? pcm.subarray(pos, pos + CHUNK) : Buffer.alloc(CHUNK);
      pos += CHUNK;
      const out = { source: "microphone", data: Buffer.from(data), sampleRate: SAMPLE_RATE };
      for (const cb of this.chunkListeners) cb(out);
    }, 32);
  }

  async stop() {
    if (this.fakeTimer) {
      clearInterval(this.fakeTimer);
      this.fakeTimer = null;
      this.setStatus("idle");
      return;
    }
    if (this.status === "idle") return;
    this.setStatus("stopping");
    try {
      await this.command("stop");
    } catch (err) {
      log.warn(`[audio] stop: ${err.message}`);
    } finally {
      this.setStatus("idle");
      log.info("[audio] stopped");
    }
  }

  async shutdown() {
    await this.stop();
    this.windows.first("mic")?.destroy();
  }
}
