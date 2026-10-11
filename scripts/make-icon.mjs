// Draws Halo's app icon (orange orb in a ring on a dark rounded square) and
// writes build/icon.icns.
//
//   npx electron scripts/make-icon.mjs
import { app, BrowserWindow } from "electron";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OUT = path.join(ROOT, "build");

const DRAW = `(() => {
  const S = 1024, c = document.createElement("canvas");
  c.width = c.height = S;
  const g = c.getContext("2d");
  // macOS icon grid: 824 px rounded square centered in 1024.
  const m = 100, r = 185, w = S - 2 * m;
  g.beginPath();
  g.roundRect(m, m, w, w, r);
  const bg = g.createLinearGradient(0, m, 0, S - m);
  bg.addColorStop(0, "#2b2e35");
  bg.addColorStop(1, "#0d0f12");
  g.fillStyle = bg;
  g.fill();
  g.save();
  g.clip();
  // soft orange glow behind the orb
  const glow = g.createRadialGradient(512, 512, 40, 512, 512, 420);
  glow.addColorStop(0, "rgba(255,72,0,0.45)");
  glow.addColorStop(1, "rgba(255,72,0,0)");
  g.fillStyle = glow;
  g.fillRect(0, 0, S, S);
  // the halo ring
  g.lineWidth = 26;
  g.strokeStyle = "rgba(255,255,255,0.88)";
  g.shadowColor = "rgba(255,138,85,0.8)";
  g.shadowBlur = 30;
  g.beginPath();
  g.arc(512, 512, 290, 0, Math.PI * 2);
  g.stroke();
  g.shadowBlur = 0;
  // the orb
  const orb = g.createRadialGradient(450, 440, 20, 512, 512, 190);
  orb.addColorStop(0, "#ffb08a");
  orb.addColorStop(0.55, "#ff4800");
  orb.addColorStop(1, "#c43500");
  g.fillStyle = orb;
  g.beginPath();
  g.arc(512, 512, 190, 0, Math.PI * 2);
  g.fill();
  g.restore();
  // hairline edge
  g.beginPath();
  g.roundRect(m + 1, m + 1, w - 2, w - 2, r);
  g.lineWidth = 2;
  g.strokeStyle = "rgba(255,255,255,0.08)";
  g.stroke();
  return c.toDataURL("image/png");
})()`;

app.whenReady().then(async () => {
  const win = new BrowserWindow({ show: false, width: 64, height: 64 });
  await win.loadURL("data:text/html,<html><body></body></html>");
  const dataUrl = await win.webContents.executeJavaScript(DRAW);
  const png = Buffer.from(dataUrl.split(",")[1], "base64");
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, "icon.png"), png);

  const iconset = fs.mkdtempSync(path.join(os.tmpdir(), "halo-icon-")) + "/icon.iconset";
  fs.mkdirSync(iconset);
  for (const size of [16, 32, 128, 256, 512]) {
    for (const scale of [1, 2]) {
      const px = size * scale;
      const name = `icon_${size}x${size}${scale === 2 ? "@2x" : ""}.png`;
      execFileSync("sips", ["-z", String(px), String(px), path.join(OUT, "icon.png"), "--out", path.join(iconset, name)], { stdio: "ignore" });
    }
  }
  execFileSync("iconutil", ["-c", "icns", iconset, "-o", path.join(OUT, "icon.icns")]);
  console.log("wrote build/icon.png and build/icon.icns");
  app.exit(0);
});
