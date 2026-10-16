// Connects Claude Code to Mercy: adds claude-hook.sh to ~/.claude/settings.json
// for the events Mercy follows. Other hooks in that file are left alone, and
// the file is backed up (settings.json.mercy-backup) before the first change.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { UNPACKED } from "../paths.js";
import { bridgeFile } from "./bridge.js";
import { log } from "../log.js";

const SETTINGS = path.join(os.homedir(), ".claude", "settings.json");
const SCRIPT = path.join(UNPACKED, "main", "mac", "claude-hook.sh");
const MARK = "claude-hook.sh";
const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"];

const q = (s) => `'${s.replace(/'/g, `'\\''`)}'`;
const command = (extra = "") => `/bin/sh ${q(SCRIPT)} ${q(bridgeFile())}${extra}`;
const isMercy = (h) => typeof h?.command === "string" && h.command.includes(MARK);

function read() {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS, "utf8"));
  } catch (err) {
    if (err.code === "ENOENT") return {};
    throw new Error(`Couldn't read ${SETTINGS}: ${err.message}`);
  }
}

function write(settings) {
  fs.mkdirSync(path.dirname(SETTINGS), { recursive: true });
  const backup = SETTINGS + ".mercy-backup";
  if (fs.existsSync(SETTINGS) && !fs.existsSync(backup)) fs.copyFileSync(SETTINGS, backup);
  const tmp = SETTINGS + ".mercy-tmp";
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + "\n");
  fs.renameSync(tmp, SETTINGS);
}

/** settings.hooks without any of Mercy's entries. */
function withoutMercy(hooks = {}) {
  const out = {};
  for (const [event, groups] of Object.entries(hooks)) {
    const kept = (groups ?? [])
      .map((g) => ({ ...g, hooks: (g.hooks ?? []).filter((h) => !isMercy(h)) }))
      .filter((g) => g.hooks.length);
    if (kept.length) out[event] = kept;
  }
  return out;
}

/** "on": installed and pointing at this copy of Mercy · "stale": another copy · "off" */
export function hooksState() {
  const all = Object.values(read().hooks ?? {}).flatMap((groups) => (groups ?? []).flatMap((g) => g.hooks ?? []));
  const mine = all.filter(isMercy);
  if (!mine.length) return "off";
  return mine.every((h) => h.command.startsWith(command())) ? "on" : "stale";
}

export function installHooks() {
  const settings = read();
  const hooks = withoutMercy(settings.hooks);
  for (const event of EVENTS) {
    (hooks[event] ??= []).push({ hooks: [{ type: "command", command: command(), async: true }] });
  }
  // Answered by Mercy (or passed back to the terminal) within ~55 s.
  (hooks.PermissionRequest ??= []).push({ hooks: [{ type: "command", command: command(" permission"), timeout: 60 }] });
  write({ ...settings, hooks });
  log.info(`[claude] hooks installed in ${SETTINGS}`);
}

export function uninstallHooks() {
  const settings = read();
  const hooks = withoutMercy(settings.hooks);
  const next = { ...settings, hooks };
  if (!Object.keys(hooks).length) delete next.hooks;
  write(next);
  log.info(`[claude] hooks removed from ${SETTINGS}`);
}
