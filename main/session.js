// Conversation session + Mercy's panel window.
// A session is open while Mercy is in use (Deepgram sockets connected); the
// sessionId is local. The panel drops down at the top-right of the screen,
// where the pill sits (main/pill.js).
import { screen } from "electron";
import crypto from "node:crypto";
import { store } from "./store.js";
import { log } from "./log.js";

const PANEL = { width: 340, height: 220, top: 6 };

export class SessionService {
  /**
   * @param {import("./gateway.js").Gateway} gateway
   * @param {import("./windows.js").WindowRegistry} windows
   */
  constructor(gateway, windows) {
    this.gateway = gateway;
    this.windows = windows;
    this.status = "idle";
    this.sessionId = null;
    this.context = null; // { language, codingLanguage }
    this.listeners = new Set();
    this.panelListeners = new Set();
  }

  onChange(cb) {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  snapshot() {
    return { status: this.status, sessionId: this.sessionId };
  }

  setStatus(status) {
    this.status = status;
    for (const cb of this.listeners) cb(this.snapshot(), this.context);
  }

  start() {
    if (this.status === "active") return { sessionId: this.sessionId, isNewSession: false };
    const prefs = store.get("userPrefs");
    this.sessionId = crypto.randomUUID();
    this.context = { language: prefs.language, codingLanguage: prefs.coding_language };
    log.info(`[session] start ${this.sessionId}`);
    this.setStatus("active");
    return { sessionId: this.sessionId, isNewSession: true };
  }

  end() {
    if (this.status === "idle") return;
    log.info(`[session] end ${this.sessionId}`);
    this.setStatus("ending");
    this.sessionId = null;
    this.context = null;
    this.setStatus("idle");
  }

  // ── panel window ───────────────────────────────────────────────────
  panel() {
    return this.windows.first("panel");
  }

  /** Show the panel at the top-right. `focus`: opened by a click (closes on click-away). */
  showPanel({ focus = false } = {}) {
    const win = this.panel() ?? this.createPanel();
    if (!win.isVisible()) this.placeTopRight(win);
    // Opened by a click → closes when you click elsewhere. Opened by Mercy
    // itself (permission card, code answer…) → no focus, stays until idle.
    this.closeOnBlur = focus;
    if (focus) {
      win.show();
      win.focus();
    } else win.showInactive();
  }

  /** The panel just closed because the user clicked away (e.g. on the menu bar icon). */
  justBlurred() {
    return Date.now() - (this.blurHiddenAt ?? 0) < 300;
  }

  /** Top-right under the menu bar — where the pill sits, so the panel grows out of it. */
  placeTopRight(win) {
    const work = screen.getPrimaryDisplay().workArea;
    const b = win.getBounds();
    win.setPosition(work.x + work.width - b.width - 10, work.y + PANEL.top);
  }

  /** @param {(visible: boolean) => void} cb called when the panel opens or closes */
  onPanelChange(cb) {
    this.panelListeners.add(cb);
  }

  /** Created hidden at launch; shown from the menu bar, the pill, or by Mercy. */
  createPanel() {
    const work = screen.getPrimaryDisplay().workArea;
    const win = this.windows.open("panel", {
      show: false,
      x: work.x + work.width - PANEL.width - 10,
      y: work.y + PANEL.top,
      width: PANEL.width,
      height: PANEL.height,
      frame: false,
      // Native frosted glass (NSVisualEffectView), kept while unfocused.
      vibrancy: "hud",
      visualEffectState: "active",
      backgroundColor: "#00000000",
      roundedCorners: true,
      hasShadow: true,
      resizable: false,
      fullscreenable: false,
      minimizable: false,
      maximizable: false,
      alwaysOnTop: true,
      skipTaskbar: true,
      hiddenInMissionControl: true,
      // NSPanel: floats over every Space and full-screen app.
      type: "panel",
      // Mercy's voice plays in the panel without a click first.
      webPreferences: { autoplayPolicy: "no-user-gesture-required" },
    });
    const pin = () => {
      win.setAlwaysOnTop(true, "screen-saver");
      win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    };
    pin();
    // macOS can drop the all-Spaces behavior when a hidden window is first
    // shown, and full-screen apps / Space switches can knock it off: re-assert.
    win.once("show", pin);
    const keepPinned = setInterval(() => {
      if (win.isDestroyed()) return clearInterval(keepPinned);
      if (!win.isAlwaysOnTop() || !win.isVisibleOnAllWorkspaces()) pin();
    }, 500);
    for (const ev of ["show", "hide"]) win.on(ev, () => this.panelListeners.forEach((cb) => cb(ev === "show")));
    // Click anywhere else → close, like Control Center (only when opened by a click).
    win.on("blur", () => {
      if (!this.closeOnBlur || !win.isVisible()) return;
      this.blurHiddenAt = Date.now();
      win.hide();
    });
    win.on("closed", () => {
      if (this.status === "active") this.end();
    });
    return win;
  }

  /** The panel sizes itself to its content; it grows downward from the menu bar. */
  resizePanel({ width, height } = {}) {
    const win = this.panel();
    if (!win || !Number.isFinite(width) || !Number.isFinite(height)) return;
    const b = win.getBounds();
    if (b.width === width && b.height === height) return;
    const work = screen.getDisplayMatching(b).workArea;
    const x = Math.max(work.x, Math.min(Math.round(b.x + b.width - width), work.x + work.width - width));
    const y = Math.max(work.y, Math.min(b.y, work.y + work.height - height));
    win.setBounds({ x, y, width, height });
  }

  register() {
    this.gateway.handleAll({
      "mercy:resize": (req) => this.resizePanel(req),
      "mercy:hide": () => {
        this.end();
        this.panel()?.hide();
      },
      // Idle: tuck the panel back into the menu bar, keeping the conversation.
      "mercy:autoHide": () => this.panel()?.hide(),
    });
  }
}
