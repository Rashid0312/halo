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

const COLLAPSE_AFTER_MS = 3000; // after Halo is done, the strip folds back into the button

/** Answer text for a 520 pt strip: code blocks become a note, markdown symbols go. */
function stripText(md) {
  return md
    .replace(/```[\s\S]*?(```|$)/g, " [code on screen] ")
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_#>]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

export class TouchBarService {
  /**
   * @param {import("./voice.js").VoiceService} voice
   * @param {import("./realtime.js").Realtime} realtime
   * @param {import("./wake.js").WakeService} wake
   * @param {import("./gateway.js").Gateway} gateway
   */
  constructor(voice, realtime, wake, gateway) {
    this.voice = voice;
    this.realtime = realtime;
    this.wake = wake;
    this.gateway = gateway;
    this.child = null;
    this.restarts = 0;
    this.stopped = false;
    this.stripAvailable = false; // full-width strip works on this Mac
    this.expanded = false;
    this.you = new Map(); // transcript segment → text, while listening
    this.answer = "";
    this.answerTimer = null;
  }

  async register() {
    if (process.platform !== "darwin") return;
    try {
      await buildTouchBarHelper();
    } catch (err) {
      log.warn(`[touchbar] helper not available (${err.code === "ENOENT" ? "no swiftc" : err.message.split("\n")[0]}) — no Touch Bar button`);
      return;
    }
    this.voice.onStateChange(() => this.sync());
    this.wake.onChange(() => this.sync());
    this.realtime.onFrame((f) => this.onFrame(f));
    // Her voice level from the panel's audio meter → the face's mouth.
    this.gateway.handle("halo:level", (v) => this.send(`level ${Number(v).toFixed(2)}`));
    this.start();
  }

  /** Halo's state as the strip shows it; expand while active, fold back after. */
  sync() {
    const followup = this.voice.state === "idle" && this.wake.mode === "followup";
    const state = followup ? "followup" : this.voice.state;
    this.send(`state ${state}`);
    if (state === "listening") this.you.clear();
    clearTimeout(this.collapseTimer);
    if (state !== "idle") return this.expand();
    this.collapseTimer = setTimeout(() => this.collapse(), COLLAPSE_AFTER_MS);
  }

  expand() {
    if (!this.stripAvailable || this.expanded) return;
    this.expanded = true;
    this.send("expand");
  }

  collapse() {
    if (!this.expanded) return;
    this.expanded = false;
    this.send("collapse");
  }

  onFrame(frame) {
    const d = frame.data ?? {};
    if (frame.type === "transcript" && d.role === "user" && this.voice.state === "listening" && d.text) {
      this.you.set(d.segment_id, d.text);
      this.send(`you ${[...this.you.values()].join(" ").replace(/\s+/g, " ")}`);
    } else if (frame.type === "turn.started") {
      this.answer = "";
      this.send("halo ");
    } else if (frame.type === "turn.token") {
      this.answer += d.delta;
      // ~10 updates a second is plenty for the strip.
      this.answerTimer ??= setTimeout(() => {
        this.answerTimer = null;
        this.send(`halo ${stripText(this.answer)}`);
      }, 100);
    } else if (frame.type === "turn.done") {
      this.send(`halo ${stripText(this.answer)}`);
    }
  }

  start() {
    if (this.stopped) return;
    const args = process.env.HALO_TOUCHBAR_TAP_AFTER ? ["--tap-after", process.env.HALO_TOUCHBAR_TAP_AFTER] : [];
    const child = spawn(BINARY, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.expanded = false;
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      if (line === "ready") {
        log.info("[touchbar] Halo button is in the Control Strip");
        this.sync();
      } else if (line === "strip ok") {
        this.stripAvailable = true;
      } else if (line === "tap") {
        log.info("[touchbar] tapped");
        this.voice.toggle();
      } else if (line === "close") {
        // The strip's ✕: stop whatever Halo is doing.
        log.info("[touchbar] closed");
        this.expanded = false;
        if (this.voice.state === "listening") this.voice.cancelListening();
        else this.voice.stopSpeaking();
      }
    });
    child.stderr.on("data", (d) => log.warn(`[touchbar] ${String(d).trim()}`));
    child.on("exit", (code) => {
      if (this.child === child) this.child = null;
      this.stripAvailable = false;
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
    if (this.child?.stdin.writable) this.child.stdin.write(`${line.replace(/\n/g, " ")}\n`);
  }

  stop() {
    this.stopped = true;
    // Closing stdin makes the helper fold the strip, remove the button and exit.
    this.child?.stdin.end();
  }
}
