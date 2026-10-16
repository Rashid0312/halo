// Claude Code sessions on this Mac, as seen through their hooks (bridge.js).
//
//   SessionStart → idle · UserPromptSubmit/PreToolUse → working
//   Notification/PermissionRequest → waiting · Stop → idle (+ its reply)
//   SessionEnd → gone
//
// A session started before Mercy shows up on its next event.
import fs from "node:fs";
import path from "node:path";
import { log } from "../log.js";

const STALE_MS = 12 * 3600 * 1000;
const TAIL_BYTES = 2 * 1024 * 1024;
const norm = (s) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** One line on what a tool call is doing, e.g. "running npm test". */
export function describeTool(name, input = {}) {
  const file = input.file_path ? path.basename(input.file_path) : "";
  switch (name) {
    case "Bash":
      return `running ${String(input.command ?? "").split("\n")[0].slice(0, 80)}`;
    case "Edit":
    case "MultiEdit":
      return `editing ${file}`;
    case "Write":
      return `writing ${file}`;
    case "Read":
      return `reading ${file}`;
    case "Grep":
    case "Glob":
      return "searching the code";
    case "WebFetch":
    case "WebSearch":
      return "looking something up online";
    case "Agent":
    case "Task":
      return "running a subagent";
    default:
      return `using ${name}`;
  }
}

export class Sessions {
  constructor() {
    this.map = new Map(); // session_id → session
    this.listeners = new Set();
  }

  /** @param {(event: string, session: object, evt: object) => void} cb */
  on(cb) {
    this.listeners.add(cb);
  }

  emit(event, s, evt) {
    for (const cb of this.listeners) {
      try {
        cb(event, s, evt);
      } catch (err) {
        log.error(`[claude] listener: ${err.stack ?? err}`);
      }
    }
  }

  /** A hook event from claude-hook.sh; tty is Claude's terminal ("/dev/ttys003") or "". */
  ingest(evt, tty) {
    const id = evt?.session_id;
    if (!id) return;
    const now = Date.now();
    let s = this.map.get(id);
    if (!s) {
      s = { id, cwd: evt.cwd, project: path.basename(evt.cwd ?? "") || "claude", tty: "", status: "idle", activity: "", startedAt: now, lastPrompt: "", lastReply: "", goal: null };
      this.map.set(id, s);
      log.info(`[claude] new session ${id.slice(0, 8)} in ${s.cwd}`);
    }
    if (tty) s.tty = tty;
    if (evt.transcript_path) s.transcript = evt.transcript_path;
    if (evt.cwd) s.cwd = evt.cwd;
    s.updatedAt = now;
    switch (evt.hook_event_name) {
      case "SessionStart":
        s.status = "idle";
        s.activity = "";
        if (evt.session_title) s.title = evt.session_title;
        break;
      case "UserPromptSubmit":
        s.status = "working";
        s.activity = "thinking";
        s.lastPrompt = String(evt.prompt ?? "").slice(0, 2000);
        s.promptAt = now;
        // Typed by Mercy (claude_send / driver) rather than the user at the keyboard.
        s.viaMercy = Boolean(s.mercySentAt && now - s.mercySentAt < 15000);
        break;
      case "PreToolUse":
        s.status = "working";
        s.activity = describeTool(evt.tool_name, evt.tool_input);
        break;
      case "Notification":
        if (evt.notification_type === "idle_prompt") s.status = "idle";
        else if (/permission|elicitation|needs_input/.test(evt.notification_type ?? "")) {
          s.status = "waiting";
          s.activity = evt.message ?? "waiting for you";
        }
        break;
      case "PermissionRequest":
        s.status = "waiting";
        s.activity = `waiting for permission: ${describeTool(evt.tool_name, evt.tool_input)}`;
        break;
      case "Stop":
        s.status = "idle";
        s.activity = "";
        s.lastReply = String(evt.last_assistant_message ?? "").slice(0, 4000);
        break;
      case "SessionEnd":
        s.status = "ended";
        this.map.delete(id);
        break;
    }
    log.debug(`[claude] ${s.project} ${evt.hook_event_name} → ${s.status}${s.activity ? ` (${s.activity})` : ""}`);
    this.emit(evt.hook_event_name, s, evt);
    this.prune();
  }

  prune() {
    for (const [id, s] of this.map) if (Date.now() - s.updatedAt > STALE_MS) this.map.delete(id);
  }

  list() {
    this.prune();
    const all = [...this.map.values()].sort((a, b) => a.startedAt - b.startedAt);
    return all.map((s) => ({ ...s, name: this.nameOf(s, all) }));
  }

  /** Spoken name: the project folder, numbered when two share it ("halo 2"). */
  nameOf(s, all = [...this.map.values()].sort((a, b) => a.startedAt - b.startedAt)) {
    const same = all.filter((x) => x.project === s.project);
    return same.length > 1 ? `${s.project} ${same.indexOf(s) + 1}` : s.project;
  }

  /**
   * The session the user means: "halo", "halo 2", "the one waiting", or "" when
   * there's only one (or one that's waiting).
   */
  find(query) {
    const all = this.list();
    if (!all.length) return null;
    const q = norm(query);
    if (!q || /^(claude|it|the one|that one)$/.test(q)) {
      const waiting = all.filter((s) => s.status === "waiting");
      if (all.length === 1) return all[0];
      if (waiting.length === 1) return waiting[0];
      return all.reduce((a, b) => (b.updatedAt > a.updatedAt ? b : a));
    }
    if (/\bwait/.test(q)) return all.find((s) => s.status === "waiting") ?? null;
    let best = null;
    for (const s of all) {
      const n = norm(s.name);
      const p = norm(s.project);
      let score = 0;
      if (n === q || s.id.startsWith(query)) score = 100;
      else if (p === q) score = 80;
      else if (n.includes(q) || q.includes(n)) score = 60;
      else if (norm(s.cwd).includes(q)) score = 40;
      if (score && (!best || score > best.score || (score === best.score && s.updatedAt > best.s.updatedAt))) best = { s, score };
    }
    return best?.s ?? null;
  }

  get(id) {
    return this.map.get(id) ?? null;
  }
}

/**
 * What happened since the last prompt, from the transcript: files changed,
 * commands run (with failures) and the final reply. Small enough for the brain.
 */
export function readTranscript(file) {
  const out = { prompt: "", reply: "", files: [], commands: [], errors: [] };
  if (!file) return out;
  let text;
  try {
    const fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - TAIL_BYTES);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    fs.closeSync(fd);
    text = buf.toString("utf8");
  } catch {
    return out;
  }
  const entries = [];
  for (const line of text.split("\n")) {
    try {
      entries.push(JSON.parse(line));
    } catch {}
  }
  // Start after the last real prompt (a user message that isn't a tool result).
  const isPrompt = (e) =>
    e.type === "user" &&
    (typeof e.message?.content === "string" || e.message?.content?.some?.((c) => c.type === "text")) &&
    !e.isMeta;
  let from = 0;
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isPrompt(entries[i])) {
      from = i;
      const c = entries[i].message.content;
      out.prompt = (typeof c === "string" ? c : c.filter((x) => x.type === "text").map((x) => x.text).join(" ")).slice(0, 500);
      break;
    }
  }
  const commands = new Map(); // tool_use_id → entry
  for (const e of entries.slice(from)) {
    const content = Array.isArray(e.message?.content) ? e.message.content : [];
    for (const c of content) {
      if (c.type === "tool_use") {
        if (["Edit", "Write", "MultiEdit", "NotebookEdit"].includes(c.name) && c.input?.file_path) {
          if (!out.files.includes(c.input.file_path)) out.files.push(c.input.file_path);
        } else if (c.name === "Bash") {
          const cmd = { command: String(c.input?.command ?? "").slice(0, 200), failed: false };
          commands.set(c.id, cmd);
          out.commands.push(cmd);
        }
      } else if (c.type === "tool_result" && c.is_error) {
        const cmd = commands.get(c.tool_use_id);
        if (cmd) cmd.failed = true;
        const msg = typeof c.content === "string" ? c.content : (c.content ?? []).map((x) => x.text ?? "").join(" ");
        out.errors.push(msg.slice(0, 300));
      } else if (c.type === "text" && e.type === "assistant") {
        out.reply = c.text;
      }
    }
  }
  out.reply = out.reply.slice(0, 3000);
  out.commands = out.commands.slice(-15);
  out.errors = out.errors.slice(-5);
  return out;
}
