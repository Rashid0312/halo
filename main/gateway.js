// IPC gateway: window.halo.invoke(channel, payload) in the preloads resolves
// here. Results are wrapped as { ok, value } / { ok: false, error } and the
// preloads unwrap them (throwing on ok:false).
import { ipcMain, BrowserWindow } from "electron";
import { log } from "./log.js";

export class Gateway {
  /** @param {import("./windows.js").WindowRegistry} registry */
  constructor(registry) {
    this.registry = registry;
    this.handlers = new Map();
  }

  handle(channel, handler) {
    if (!this.handlers.has(channel)) {
      ipcMain.handle(channel, (event, payload) =>
        this.invoke(channel, () => this.handlers.get(channel)(payload, this.ctx(event))),
      );
    }
    this.handlers.set(channel, handler);
  }

  /** Register many handlers: { "domain:method": fn } */
  handleAll(map) {
    for (const [channel, fn] of Object.entries(map)) this.handle(channel, fn);
  }

  async invoke(channel, run) {
    try {
      const value = await run();
      return { ok: true, value: value === undefined ? null : value };
    } catch (err) {
      const code = err?.code ?? "INTERNAL";
      log.error(`[ipc] ${channel} failed: ${err?.message ?? err}`);
      return {
        ok: false,
        error: { code, message: String(err?.message ?? err), details: err?.details },
      };
    }
  }

  ctx(event) {
    return { window: BrowserWindow.fromWebContents(event.sender) ?? undefined };
  }

  broadcast(channel, payload, options) {
    const targets = options?.to
      ? options.to.flatMap((k) => this.registry.getByKind(k))
      : this.registry.getAll();
    for (const win of targets) {
      if (!win.isDestroyed()) win.webContents.send(channel, payload);
    }
  }
}
