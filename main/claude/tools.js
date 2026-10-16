// Brain tools for Claude Code sessions (merged into TOOLS in ../tools.js).
// Mercy relays and supervises; the sessions do the engineering.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { claude } from "./index.js";
import { readTranscript } from "./sessions.js";
import { sendText, pressKey, openClaude } from "./terminal.js";

const fn = (name, description, properties = {}, required = []) => ({
  type: "function",
  function: { name, description, parameters: { type: "object", properties, required } },
});
const str = (description) => ({ type: "string", description });
const SESSION = str("Which Claude: its project name as listed by claude_sessions (e.g. 'halo', 'halo 2'), or empty for the only/most recent one");

const NOT_CONNECTED = {
  ok: false,
  connected: false,
  error: "Claude Code isn't connected to Mercy yet. Offer to connect it (claude_connect).",
};

function pick(session) {
  if (claude.hooksState() === "off") return { error: NOT_CONNECTED };
  const s = claude.sessions.find(session);
  if (s) return { s };
  const names = claude.sessions.list().map((x) => x.name);
  return {
    error: {
      ok: false,
      error: names.length
        ? `No Claude session matches "${session}". Open ones: ${names.join(", ")}.`
        : "No Claude Code sessions are open (one opened before Mercy shows up once it does something).",
    },
  };
}

const PROJECT_DIRS = ["", "Desktop", "Documents", "Developer", "code", "Code", "projects", "Projects", "src", "dev"].map((d) => path.join(os.homedir(), d));
const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** "halo", "~/Desktop/halo", "/abs/path" → an existing folder, or null. */
function findFolder(name) {
  const raw = String(name ?? "").trim();
  if (!raw) return null;
  const expanded = raw.replace(/^~(?=$|\/)/, os.homedir());
  if (path.isAbsolute(expanded)) return fs.existsSync(expanded) && fs.statSync(expanded).isDirectory() ? expanded : null;
  const known = claude.sessions.list().find((s) => norm(s.project) === norm(raw));
  if (known) return known.cwd;
  const q = norm(raw);
  for (const dir of PROJECT_DIRS) {
    let entries = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    const hit = entries.find((e) => e.isDirectory() && norm(e.name) === q) ?? entries.find((e) => e.isDirectory() && !e.name.startsWith(".") && norm(e.name).includes(q));
    if (hit) return path.join(dir, hit.name);
  }
  return null;
}

export const CLAUDE_TOOLS = {
  claude_sessions: {
    def: fn("claude_sessions", "List the Claude Code (coding agent) sessions open on this Mac: project, status (working / waiting for the user / idle) and what each is doing."),
    run() {
      if (claude.hooksState() === "off") return NOT_CONNECTED;
      return {
        ok: true,
        sessions: claude.sessions.list().map((s) => ({
          name: s.name,
          folder: s.cwd,
          status: s.status,
          doing: s.activity || undefined,
          lastPrompt: s.lastPrompt.slice(0, 200) || undefined,
          drivingGoal: s.goal?.text,
          canType: Boolean(s.tty),
        })),
      };
    },
  },
  claude_read: {
    def: fn("claude_read", "What a Claude Code session did for its last prompt: its reply, files it changed, commands it ran and any failures.", { session: SESSION }),
    run({ session }) {
      const { s, error } = pick(session);
      if (error) return error;
      const t = readTranscript(s.transcript);
      return {
        ok: true,
        name: s.name,
        status: s.status,
        doing: s.activity || undefined,
        prompt: t.prompt || s.lastPrompt,
        reply: t.reply || s.lastReply,
        filesChanged: t.files.map((f) => path.relative(s.cwd, f) || f),
        commands: t.commands.map((c) => (c.failed ? `${c.command}  [failed]` : c.command)),
        errors: t.errors,
      };
    },
  },
  claude_send: {
    def: fn(
      "claude_send",
      "Type a message into a Claude Code session, as if the user typed it: a prompt, an answer to its question (e.g. '2' for option 2, with press_return false), or a slash command. Pass the user's words faithfully.",
      { session: SESSION, text: str("Exactly what to type"), press_return: { type: "boolean", description: "Press Return after (default true)" } },
      ["text"],
    ),
    async run({ session, text, press_return = true }) {
      const { s, error } = pick(session);
      if (error) return error;
      text = String(text ?? "").trim();
      if (!text) return { ok: false, error: "Nothing to send." };
      s.mercySentAt = Date.now();
      await sendText(s.tty, text, { submit: press_return !== false });
      return { ok: true, sentTo: s.name };
    },
  },
  claude_interrupt: {
    def: fn("claude_interrupt", "Stop what a Claude Code session is doing right now (presses Esc).", { session: SESSION }),
    async run({ session }) {
      const { s, error } = pick(session);
      if (error) return error;
      await pressKey(s.tty, "escape");
      return { ok: true, interrupted: s.name };
    },
  },
  claude_start: {
    def: fn(
      "claude_start",
      "Open a new Claude Code session in a Terminal window, in a project folder, optionally with a first prompt.",
      { folder: str("Folder name or path, e.g. 'halo' or '~/Desktop/halo'"), prompt: str("First prompt (optional)") },
      ["folder"],
    ),
    async run({ folder, prompt }) {
      if (claude.hooksState() === "off") return NOT_CONNECTED;
      const dir = findFolder(folder);
      if (!dir) return { ok: false, error: `No folder named "${folder}" in your home, Desktop, Documents or code folders. Ask for the path.` };
      await openClaude(dir, prompt?.trim());
      return { ok: true, folder: dir, note: "It shows up in claude_sessions once it starts." };
    },
  },
  claude_drive: {
    def: fn(
      "claude_drive",
      "Let Mercy keep a Claude Code session going toward a goal: after each of its replies Mercy decides whether to continue, stop, or ask the user. Use when the user says things like 'keep going until the tests pass'.",
      {
        session: SESSION,
        goal: str("The goal in the user's words"),
        max_steps: { type: "integer", description: "Most follow-ups Mercy may send (default 8, max 20)" },
      },
      ["goal"],
    ),
    async run({ session, goal, max_steps = 8 }) {
      const { s, error } = pick(session);
      if (error) return error;
      if (!s.tty) return { ok: false, error: "Mercy can't type into that Claude's terminal, so she can't drive it." };
      await claude.driver.start(s, String(goal ?? "").trim(), Math.min(20, Math.max(1, Number(max_steps) || 8)));
      return { ok: true, driving: s.name, note: "Mercy will report when it's done or needs the user." };
    },
  },
  claude_stop_driving: {
    def: fn("claude_stop_driving", "Stop Mercy driving a Claude Code session (claude_drive). Claude itself keeps whatever it's doing; use claude_interrupt to stop that too.", { session: SESSION }),
    run({ session }) {
      const driven = claude.sessions.list().filter((x) => x.goal);
      const s = session ? claude.sessions.find(session) : driven.length === 1 ? driven[0] : null;
      if (!s?.goal) return { ok: false, error: driven.length ? `Driving: ${driven.map((x) => x.name).join(", ")}. Which one?` : "Mercy isn't driving any Claude." };
      claude.driver.stop(s, "the user asked");
      return { ok: true, stopped: s.name };
    },
  },
  claude_connect: {
    def: fn("claude_connect", "Connect Claude Code to Mercy (adds Mercy's hooks to ~/.claude/settings.json) so she can see its sessions. The user approves first."),
    run: (_args, ctx) => claude.connect(ctx),
  },
};

/** Panel label for a claude_* tool call, or null. */
export function claudeLabel(name, args = {}) {
  const who = args.session ? `Claude (${args.session})` : "Claude";
  switch (name) {
    case "claude_sessions":
      return "Checking your Claude sessions";
    case "claude_read":
      return `Reading what ${who} did`;
    case "claude_send":
      return `Telling ${who}: ${String(args.text ?? "").slice(0, 60)}`;
    case "claude_interrupt":
      return `Stopping ${who}`;
    case "claude_start":
      return `Starting Claude in ${args.folder}`;
    case "claude_drive":
      return `Driving ${who}: ${args.goal}`;
    case "claude_stop_driving":
      return `No longer driving ${who}`;
    case "claude_connect":
      return "Connecting Claude Code";
    default:
      return null;
  }
}
