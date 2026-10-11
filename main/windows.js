// Window registry + factories for Halo's windows.
import { BrowserWindow } from "electron";
import path from "node:path";
import { ROOT } from "./paths.js";
import { log } from "./log.js";

const ENTRIES = {
  // Halo's panel (drops down from the menu bar / pill).
  panel: { html: "halo-panel", preload: "halo.cjs" },
  // The "mic bubble" shown while Halo is active.
  pill: { html: "halo-pill", preload: "pill.cjs" },
  // Hidden window that records the microphone (main/audio.js).
  mic: { html: "halo-mic", preload: "mic.cjs" },
};

export class WindowRegistry {
  constructor() {
    /** @type {Map<string, Set<BrowserWindow>>} */
    this.byKind = new Map();
  }

  add(kind, win) {
    if (!this.byKind.has(kind)) this.byKind.set(kind, new Set());
    this.byKind.get(kind).add(win);
    win.once("closed", () => this.byKind.get(kind)?.delete(win));
  }

  getByKind(kind) {
    return [...(this.byKind.get(kind) ?? [])].filter((w) => !w.isDestroyed());
  }

  first(kind) {
    return this.getByKind(kind)[0];
  }

  getAll() {
    return BrowserWindow.getAllWindows();
  }

  /** Create one of Halo's windows. */
  open(kind, options = {}) {
    const entry = ENTRIES[kind];
    if (!entry) throw new Error(`unknown window kind ${kind}`);
    const win = new BrowserWindow({
      show: false,
      ...options,
      webPreferences: {
        preload: path.join(ROOT, "preload", entry.preload),
        contextIsolation: true,
        sandbox: false,
        nodeIntegration: false,
        ...options.webPreferences,
      },
    });
    this.add(kind, win);
    win.loadFile(path.join(ROOT, "renderer", entry.html, "index.html"));
    win.once("ready-to-show", () => {
      if (options.show !== false) win.show();
    });
    if (process.env.HALO_DEVTOOLS === "1") {
      win.webContents.openDevTools({ mode: "detach" });
    }
    // A crashed page (out of memory, GPU reset…) reloads instead of leaving a blank window.
    win.webContents.on("render-process-gone", (_e, details) => {
      log.warn(`[${kind}] page crashed (${details.reason}), reloading`);
      if (!win.isDestroyed()) win.reload();
    });
    win.webContents.on("console-message", (e) => {
      if (e.level === "error") log.error(`[${kind}] ${e.message}`);
    });
    return win;
  }
}
