// "Look at my screen": screenshot the display the mouse is on (Halo's own
// windows are kept out of the shot) and ask the vision model about it.
import { BrowserWindow, desktopCapturer, screen } from "electron";
import { log } from "./log.js";

const MAX_WIDTH = 1600; // enough to read code and small text
const JPEG_QUALITY = 80;
const HIDE_SETTLE_MS = 120; // let macOS apply content protection before capturing

export class ScreenService {
  /**
   * @param {import("./realtime.js").Realtime} realtime
   * @param {import("./session.js").SessionService} session
   * @param {import("./brain.js").Brain} brain
   */
  constructor(realtime, session, brain) {
    this.realtime = realtime;
    this.session = session;
    this.brain = brain;
  }

  /** Capture the screen under the cursor as a base64 JPEG. */
  async capture() {
    const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
    const windows = BrowserWindow.getAllWindows().filter((w) => !w.isDestroyed());
    for (const w of windows) w.setContentProtection(true);
    await new Promise((r) => setTimeout(r, HIDE_SETTLE_MS));
    try {
      const size = {
        width: Math.round(display.bounds.width * display.scaleFactor),
        height: Math.round(display.bounds.height * display.scaleFactor),
      };
      const sources = await desktopCapturer.getSources({ types: ["screen"], thumbnailSize: size, fetchWindowIcons: false });
      const source = sources.find((s) => s.display_id === String(display.id)) ?? sources[0];
      if (!source || source.thumbnail.isEmpty()) {
        throw Object.assign(new Error("Halo can't see the screen yet — allow it in System Settings → Privacy & Security → Screen Recording"), {
          code: "PROCEDURAL",
        });
      }
      const img = source.thumbnail.getSize().width > MAX_WIDTH ? source.thumbnail.resize({ width: MAX_WIDTH, quality: "best" }) : source.thumbnail;
      return img.toJPEG(JPEG_QUALITY).toString("base64");
    } finally {
      for (const w of windows) if (!w.isDestroyed()) w.setContentProtection(false);
    }
  }

  async solve() {
    if (this.session.status !== "active") this.session.start();
    const image = await this.capture();
    log.info("[screen] captured, asking the vision model");
    this.realtime.emit({ type: "screen.analysed", data: { title: "Looking at your screen…" } });
    void this.brain.solveScreen([image]);
  }
}
