// The "mic bubble": while Halo is active (listening, thinking, speaking,
// waiting for an OK, or in the follow-up window) a small pill hangs under the
// right end of the menu bar — like macOS's "🎙 Terminal" bubble. Clicking it
// opens the full panel, which grows from the same spot. Idle → no pill.
import { screen } from "electron";
import { log } from "./log.js";

const LINGER_MS = 1500; // keep the pill a moment after Halo goes idle
const OUT_MS = 250; // fade-out animation in pill.css
const RIGHT_MARGIN = 10; // capsule's right edge from the screen edge (matches the panel)
const PAD = { x: 8, top: 6 }; // body padding around the capsule in pill.css

export class PillService {
  /**
   * @param {import("./windows.js").WindowRegistry} windows
   * @param {import("./session.js").SessionService} session
   * @param {import("./voice.js").VoiceService} voice
   * @param {import("./wake.js").WakeService} wake
   * @param {import("./gateway.js").Gateway} gateway
   */
  constructor(windows, session, voice, wake, gateway) {
    this.windows = windows;
    this.session = session;
    this.voice = voice;
    this.wake = wake;
    this.gateway = gateway;
    this.size = { width: 200, height: 48 };
    this.hideTimer = null;
  }

  register() {
    this.gateway.handleAll({
      "halo:openPanel": () => {
        this.session.showPanel({ focus: true });
        this.gateway.broadcast("halo:openComposer", null, { to: ["panel"] });
      },
      "halo:pillResize": ({ width, height } = {}) => {
        if (!Number.isFinite(width) || !Number.isFinite(height)) return;
        this.size = { width, height };
        this.place();
      },
    });
    this.voice.onStateChange(() => this.update());
    this.wake.onChange(() => this.update());
    this.session.onPanelChange(() => this.update());
  }

  active() {
    return this.voice.state !== "idle" || this.wake.mode === "followup";
  }

  update() {
    const panelOpen = this.session.panel()?.isVisible();
    if (panelOpen) return this.hide(false);
    if (this.active()) return this.show();
    // Done: linger briefly (an answer may follow), then fade out.
    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => !this.active() && this.hide(true), LINGER_MS);
  }

  win() {
    const existing = this.windows.first("pill");
    if (existing) return existing;
    const win = this.windows.open("pill", {
      show: false,
      width: this.size.width,
      height: this.size.height,
      frame: false,
      transparent: true,
      hasShadow: false,
      resizable: false,
      focusable: false, // never steals focus from the app you're in
      fullscreenable: false,
      minimizable: false,
      maximizable: false,
      alwaysOnTop: true,
      skipTaskbar: true,
      hiddenInMissionControl: true,
      type: "panel",
    });
    win.setAlwaysOnTop(true, "screen-saver");
    win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true, skipTransformProcessType: true });
    return win;
  }

  place() {
    const win = this.windows.first("pill");
    if (!win) return;
    const work = screen.getPrimaryDisplay().workArea;
    const { width, height } = this.size;
    win.setBounds({
      x: Math.round(work.x + work.width - RIGHT_MARGIN - width + PAD.x),
      y: work.y + 6 - PAD.top,
      width,
      height,
    });
  }

  show() {
    clearTimeout(this.hideTimer);
    const win = this.win();
    if (win.isVisible()) return;
    this.place();
    win.showInactive();
    log.debug("[pill] shown");
  }

  hide(animate) {
    clearTimeout(this.hideTimer);
    const win = this.windows.first("pill");
    if (!win?.isVisible()) return;
    if (!animate) return win.hide();
    this.gateway.broadcast("halo:pillOut", null, { to: ["pill"] });
    this.hideTimer = setTimeout(() => {
      if (!this.active() || this.session.panel()?.isVisible()) win.hide();
    }, OUT_MS);
  }
}
