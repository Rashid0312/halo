// Halo in the macOS menu bar.
//   left-click  → drop the panel down under the icon (click again to hide)
//   right-click → menu: open, "Hey Halo", speak replies, re-train voice, quit
// The icon is a template image (macOS tints it for light/dark menu bars): an
// open ring when idle, a filled orb while Halo is listening or talking.
import { Menu, Tray, nativeImage } from "electron";
import zlib from "node:zlib";
import { store } from "./store.js";
import { log } from "./log.js";

const ACTIVE = new Set(["listening", "thinking", "speaking", "waiting"]);

export class TrayService {
  /**
   * @param {import("./session.js").SessionService} session
   * @param {import("./voice.js").VoiceService} voice
   * @param {import("./wake.js").WakeService} wake
   * @param {import("./gateway.js").Gateway} gateway
   */
  constructor(session, voice, wake, gateway) {
    this.session = session;
    this.voice = voice;
    this.wake = wake;
    this.gateway = gateway;
    this.icons = { idle: icon(false), active: icon(true) };
  }

  register() {
    this.tray = new Tray(this.icons.idle);
    this.tray.setToolTip("Halo");
    // macOS hides menu bar icons that collide with the front app's menus when
    // the bar is full. Tell the user once instead of silently being invisible.
    setTimeout(() => {
      const b = this.tray.getBounds();
      if (b.y < 0 || !b.width) {
        log.warn("[tray] menu bar is full — macOS is hiding Halo's icon");
        // Explain once; after that "Hey Halo" and the pill are enough.
        const ui = store.get("ui") ?? {};
        if (!ui.trayHiddenNoticed) {
          store.set("ui", { ...ui, trayHiddenNoticed: true });
          this.session.showPanel();
          this.gateway.broadcast("halo:trayHidden", null, { to: ["panel"] });
        }
      }
    }, 1500);
    this.tray.on("click", () => this.toggle());
    this.tray.on("right-click", () => this.tray.popUpContextMenu(this.menu()));
    this.voice.onStateChange((state) => {
      this.tray.setImage(ACTIVE.has(state) ? this.icons.active : this.icons.idle);
    });
  }

  toggle() {
    const win = this.session.panel();
    // Clicking the icon while the panel is open: the click first blurs (and
    // closes) the panel; don't reopen it right away.
    if (this.session.justBlurred()) return;
    if (win?.isVisible() && win.isFocused()) {
      win.hide();
      return;
    }
    this.session.showPanel({ focus: true });
    this.gateway.broadcast("halo:openComposer", null, { to: ["panel"] });
  }

  menu() {
    const wake = this.wake.snapshot();
    const voice = store.get("voice");
    const openSetup = () => {
      this.session.showPanel({ focus: true });
      this.gateway.broadcast("halo:startEnroll", null, { to: ["panel"] });
    };
    return Menu.buildFromTemplate([
      { label: "Open Halo", click: () => this.toggle() },
      { type: "separator" },
      wake.enrolled
        ? {
            label: "“Hey Halo” — only my voice",
            type: "checkbox",
            checked: wake.enabled,
            click: async (item) => {
              store.set("wake", { ...store.get("wake"), enabled: item.checked });
              await this.wake.sync();
            },
          }
        : { label: "Set up “Hey Halo”…", enabled: wake.available, click: openSetup },
      {
        label: "Speak replies",
        type: "checkbox",
        checked: voice.enabled,
        click: (item) => this.voice.setEnabled(item.checked),
      },
      ...(wake.enrolled ? [{ label: "Re-train my voice…", click: openSetup }] : []),
      { type: "separator" },
      ...(this.loginItem
        ? [{ label: "Open at login", type: "checkbox", checked: this.loginItem.get(), click: (item) => this.loginItem.set(item.checked) }]
        : []),
      ...(this.showLogs ? [{ label: "Show logs", click: () => this.showLogs() }] : []),
      { type: "separator" },
      { label: "Quit Halo", role: "quit" },
    ]);
  }
}

// ── icon: drawn in code, 18 pt (@1x and @2x) ─────────────────────────
function icon(filled) {
  const img = nativeImage.createEmpty();
  for (const scale of [1, 2]) {
    const size = 18 * scale;
    img.addRepresentation({ scaleFactor: scale, buffer: png(size, size, (x, y) => orb(x / scale, y / scale, filled)) });
  }
  img.setTemplateImage(true);
  return img;
}

/** Coverage (0..1) at point (x, y) in an 18×18 box: a ring, plus a center orb when active. */
function orb(x, y, filled) {
  const d = Math.hypot(x - 9, y - 9);
  const ring = 1 - Math.min(1, Math.abs(d - 6.5) / 0.9); // ring radius 6.5, ~1.8 pt stroke
  const core = filled ? 1 - Math.min(1, Math.max(0, d - 3.4) / 0.6) : 0;
  return Math.max(0, ring, core);
}

/** Minimal RGBA PNG encoder. Black pixels with alpha = coverage (template image). */
function png(w, h, alphaAt) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0; // filter: none
    for (let x = 0; x < w; x++) {
      // 4×4 supersampling for smooth edges.
      let a = 0;
      for (let sy = 0; sy < 4; sy++) for (let sx = 0; sx < 4; sx++) a += alphaAt(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4);
      raw[y * (w * 4 + 1) + 1 + x * 4 + 3] = Math.round((a / 16) * 255);
    }
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

let crcTable;
function crc32(buf) {
  crcTable ??= Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
