// Halo's button in the Touch Bar Control Strip (where Siri's was).
// A small native helper (native/touchbar/HaloTouchBar.swift) owns the button;
// it prints "tap" when pressed and we send it Halo's state for the icon.
// Tap = the 🎤 path: start listening, tap again to send, tap while she talks
// to interrupt. Quietly does nothing on Macs without a Touch Bar or without
// a Swift compiler to build the helper.
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { promisify } from "node:util";
import { PACKAGED, RESOURCES, ROOT } from "./paths.js";
import { log } from "./log.js";

const DIR = path.join(ROOT, "native", "touchbar");
const SOURCE = path.join(DIR, "HaloTouchBar.swift");
// Installed app: prebuilt helper in Contents/Resources. Development: built next to its source.
const BINARY = PACKAGED ? path.join(RESOURCES, "halo-touchbar") : path.join(DIR, "halo-touchbar");
const MAX_RESTARTS = 3;

/** Compile the helper if it's missing or older than its source. */
export async function buildTouchBarHelper() {
  if (PACKAGED) {
    if (!fs.existsSync(BINARY)) throw new Error("helper missing from the app bundle");
    return BINARY;
  }
  const fresh = fs.existsSync(BINARY) && fs.statSync(BINARY).mtimeMs >= fs.statSync(SOURCE).mtimeMs;
  if (fresh) return BINARY;
  log.info("[touchbar] building the Touch Bar helper…");
  await promisify(execFile)("swiftc", ["-O", SOURCE, "-o", BINARY], { timeout: 180000 });
  return BINARY;
}

export class TouchBarService {
  /** @param {import("./voice.js").VoiceService} voice */
  constructor(voice) {
    this.voice = voice;
    this.child = null;
    this.restarts = 0;
    this.stopped = false;
  }

  async register() {
    if (process.platform !== "darwin") return;
    try {
      await buildTouchBarHelper();
    } catch (err) {
      log.warn(`[touchbar] helper not available (${err.code === "ENOENT" ? "no swiftc" : err.message.split("\n")[0]}) — no Touch Bar button`);
      return;
    }
    this.voice.onStateChange((state) => this.send(`state ${state}`));
    this.start();
  }

  start() {
    if (this.stopped) return;
    const args = process.env.HALO_TOUCHBAR_TAP_AFTER ? ["--tap-after", process.env.HALO_TOUCHBAR_TAP_AFTER] : [];
    const child = spawn(BINARY, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      if (line === "ready") {
        log.info("[touchbar] Halo button is in the Control Strip");
        this.send(`state ${this.voice.state}`);
      } else if (line === "tap") {
        log.info("[touchbar] tapped");
        this.voice.toggle();
      }
    });
    child.stderr.on("data", (d) => log.warn(`[touchbar] ${String(d).trim()}`));
    child.on("exit", (code) => {
      if (this.child === child) this.child = null;
      if (this.stopped) return;
      // 2 = this macOS doesn't support Control Strip buttons (or no Touch Bar).
      if (code === 2 || this.restarts >= MAX_RESTARTS) {
        log.warn(`[touchbar] helper exited (${code}) — Touch Bar button off`);
        return;
      }
      this.restarts++;
      log.warn(`[touchbar] helper exited (${code}), restarting`);
      setTimeout(() => this.start(), 1000 * this.restarts);
    });
  }

  send(line) {
    if (this.child?.stdin.writable) this.child.stdin.write(`${line}\n`);
  }

  stop() {
    this.stopped = true;
    // Closing stdin makes the helper remove the button and exit.
    this.child?.stdin.end();
  }
}
