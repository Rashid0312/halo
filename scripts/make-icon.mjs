// Draws Mercy's app icon (her pixel black hole on a dark rounded square) and
// writes build/icon.icns.
//
//   npx electron scripts/make-icon.mjs
import { app, BrowserWindow } from "electron";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { orbCells } from "../renderer/shared/pixel-orb.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OUT = path.join(ROOT, "build");

// One frame of Mercy's pixel black hole (renderer/shared/pixel-orb.js), mid-beat
// with a spark burst, on the dark rounded square.
let seed = 11;
const rand = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
const CELLS = orbCells({ phase: 2, state: "speaking", level: 0.9, grid: 32, rand });

const DRAW = `(() => {
  const S = 1024, c = document.createElement("canvas");
  c.width = c.height = S;
  const g = c.getContext("2d");
  // macOS icon grid: 824 px rounded square centered in 1024.
  const m = 100, r = 185, w = S - 2 * m;
  g.beginPath();
  g.roundRect(m, m, w, w, r);
  const bg = g.createLinearGradient(0, m, 0, S - m);
  bg.addColorStop(0, "#17111f");
  bg.addColorStop(1, "#0b0812");
  g.fillStyle = bg;
  g.fill();
  g.save();
  g.clip();
  // soft purple glow behind the orb
  const glow = g.createRadialGradient(512, 512, 60, 512, 512, 430);
  glow.addColorStop(0, "rgba(166,75,240,0.28)");
  glow.addColorStop(1, "rgba(166,75,240,0)");
  g.fillStyle = glow;
  g.fillRect(0, 0, S, S);
  // crisp pixels: 32-cell grid, 22 px per cell
  const cells = ${JSON.stringify(CELLS)};
  const px = 22, off = (S - 32 * px) / 2;
  for (const [x, y, color] of cells) {
    g.fillStyle = color;
    g.fillRect(off + x * px, off + y * px, px, px);
  }
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

  const iconset = fs.mkdtempSync(path.join(os.tmpdir(), "mercy-icon-")) + "/icon.iconset";
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
