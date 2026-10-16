// Typing into a Claude Code session's terminal tab, found by its tty.
// Terminal.app: the tab is brought to the front, the text pasted (the user's
// clipboard is put back afterwards) and the previous app re-focused.
// iTerm2: the text goes straight into the session, nothing moves.
// VS Code / Cursor terminals can't be reached this way.
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { clipboard } from "electron";
import { UNPACKED } from "../paths.js";
import { log } from "../log.js";

const run = promisify(execFile);
const script = (name) => path.join(UNPACKED, "main", "mac", name);
const osa = (name, ...args) => run("osascript", [script(name), ...args.map(String)], { timeout: 15000 });
const ITERM = ["/Applications/iTerm.app", path.join(os.homedir(), "Applications/iTerm.app")].some((p) => fs.existsSync(p));
const KEYS = { escape: { terminal: 53, iterm: 27 } };

async function running(name) {
  try {
    await run("pgrep", ["-xq", name]);
    return true;
  } catch {
    return false;
  }
}

// One at a time: two sends at once would fight over focus and the clipboard.
let queue = Promise.resolve();
const serial = (fn) => (queue = queue.then(fn, fn));

function saveClipboard() {
  const formats = clipboard.availableFormats();
  return {
    text: clipboard.readText(),
    html: formats.some((f) => f.includes("html")) ? clipboard.readHTML() : undefined,
    rtf: formats.some((f) => f.includes("rtf")) ? clipboard.readRTF() : undefined,
    image: formats.some((f) => f.startsWith("image/")) ? clipboard.readImage() : undefined,
  };
}

function restoreClipboard(saved) {
  const data = Object.fromEntries(Object.entries(saved).filter(([k, v]) => v !== undefined && (k !== "image" || !v.isEmpty())));
  if (Object.keys(data).length) clipboard.write(data);
  else clipboard.clear();
}

async function refocus(prev) {
  if (!prev || prev === "Terminal") return;
  await run("osascript", ["-e", `tell application "System Events" to set frontmost of first application process whose name is ${JSON.stringify(prev)} to true`]).catch(() => {});
}

async function viaTerminal(tty, action, arg) {
  if (!(await running("Terminal"))) return false;
  try {
    const { stdout } = await osa("terminal-tab.applescript", action, tty, arg);
    return stdout.trim() || true;
  } catch (err) {
    if (/No Terminal tab/.test(err.stderr ?? err.message)) return false;
    throw err;
  }
}

async function viaIterm(tty, ...args) {
  if (!ITERM || !(await running("iTerm2"))) return false;
  try {
    await osa("iterm-session.applescript", args[0], tty, ...args.slice(1));
    return true;
  } catch (err) {
    if (/No iTerm2 session/.test(err.stderr ?? err.message)) return false;
    throw err;
  }
}

const NOT_FOUND = "Couldn't find that Claude's terminal. Mercy can type into Terminal and iTerm2 tabs, not VS Code or Cursor terminals.";

/** Type text into the session on tty; submit presses Return. */
export function sendText(tty, text, { submit = true } = {}) {
  return serial(async () => {
    if (!tty) throw new Error(NOT_FOUND);
    if (await viaIterm(tty, "write", text.replace(/\s*\n\s*/g, " "), submit ? "1" : "0")) return;
    const saved = saveClipboard();
    clipboard.writeText(text);
    try {
      const prev = await viaTerminal(tty, "paste", submit ? "1" : "0");
      if (!prev) throw new Error(NOT_FOUND);
      await new Promise((r) => setTimeout(r, 300));
      await refocus(prev);
    } finally {
      restoreClipboard(saved);
    }
    log.info(`[claude] typed ${text.length} chars into ${tty}${submit ? " + Return" : ""}`);
  });
}

/** Press a key ("escape") in the session on tty. */
export function pressKey(tty, key) {
  return serial(async () => {
    if (!tty) throw new Error(NOT_FOUND);
    const k = KEYS[key];
    if (await viaIterm(tty, "char", k.iterm)) return;
    const prev = await viaTerminal(tty, "key", k.terminal);
    if (!prev) throw new Error(NOT_FOUND);
    await refocus(prev);
  });
}

const sq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

/** Start Claude Code in a new Terminal window, optionally with a first prompt. */
export async function openClaude(cwd, prompt) {
  const cmd = `cd ${sq(cwd)} && claude${prompt ? ` ${sq(prompt)}` : ""}`;
  await osa("terminal-open.applescript", cmd);
  log.info(`[claude] opened a new Claude in ${cwd}`);
}
