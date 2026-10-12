// Mercy's button in the Touch Bar Control Strip (where Siri's was).
// A small native helper (native/touchbar/MercyTouchBar.swift) owns the button;
// it prints "tap" when pressed and we send it Mercy's state for the icon.
// Tap = the 🎤 path: start listening, tap again to send, tap while she talks
// to interrupt. Quietly does nothing on Macs without a Touch Bar or without
// a Swift compiler to build the helper.
import { spawn } from "node:child_process";
import readline from "node:readline";
import { buildHelper, helperPath } from "./native.js";
import { log } from "./log.js";

const BINARY = helperPath("touchbar", "mercy-touchbar");
const MAX_RESTARTS = 3;

const COLLAPSE_AFTER_MS = 3000; // after Mercy is done, the strip folds back into the button

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
      await buildHelper("touchbar", "MercyTouchBar.swift", "mercy-touchbar");
    } catch (err) {
      log.warn(`[touchbar] helper not available (${err.code === "ENOENT" ? "no swiftc" : err.message.split("\n")[0]}) — no Touch Bar button`);
      return;
    }
    this.voice.onStateChange(() => this.sync());
    this.wake.onChange(() => this.sync());
    this.realtime.onFrame((f) => this.onFrame(f));
    // Her voice level from the panel's audio meter → the face's mouth.
    this.gateway.handle("mercy:level", (v) => this.send(`level ${Number(v).toFixed(2)}`));
    this.start();
  }

  /** Mercy's state as the strip shows it; expand while active, fold back after. */
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
      this.send("mercy ");
    } else if (frame.type === "turn.token") {
      this.answer += d.delta;
      // ~10 updates a second is plenty for the strip.
      this.answerTimer ??= setTimeout(() => {
        this.answerTimer = null;
        this.send(`mercy ${stripText(this.answer)}`);
      }, 100);
    } else if (frame.type === "turn.done") {
      this.send(`mercy ${stripText(this.answer)}`);
    }
  }

  start() {
    if (this.stopped) return;
    const args = process.env.MERCY_TOUCHBAR_TAP_AFTER ? ["--tap-after", process.env.MERCY_TOUCHBAR_TAP_AFTER] : [];
    const child = spawn(BINARY, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.expanded = false;
    readline.createInterface({ input: child.stdout }).on("line", (line) => {
      if (line === "ready") {
        log.info("[touchbar] Mercy button is in the Control Strip");
        this.sync();
      } else if (line === "strip ok") {
        this.stripAvailable = true;
      } else if (line === "tap") {
        log.info("[touchbar] tapped");
        this.voice.toggle();
      } else if (line === "close") {
        // The strip's ✕: stop whatever Mercy is doing.
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
