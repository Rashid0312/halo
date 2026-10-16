// Mercy ↔ Claude Code. Claude's hooks (hooks.js → claude-hook.sh) report every
// session to the bridge; Mercy keeps track of them (sessions.js), tells the
// user what happened (narrator.js), asks them about Claude's permission
// requests, types into sessions (terminal.js) and can drive one toward a goal
// (driver.js). Brain tools: tools.js.
import path from "node:path";
import { store } from "../store.js";
import { log } from "../log.js";
import { riskyCommand, simpleProgram } from "../tools.js";
import { Bridge } from "./bridge.js";
import { hooksState, installHooks, uninstallHooks } from "./hooks.js";
import { Sessions, describeTool } from "./sessions.js";
import { Narrator } from "./narrator.js";
import { Driver } from "./driver.js";

const ANSWER_WITHIN_MS = 50000; // the hook gives up at 55 s; then Claude asks in its terminal
const READ_ONLY = new Set(["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite", "NotebookRead"]);
const EDITS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);

class ClaudeService {
  constructor() {
    this.sessions = new Sessions();
    this.narrator = new Narrator(this);
    this.driver = new Driver(this);
    this.bridge = new Bridge({
      onEvent: (evt, tty) => this.sessions.ingest(evt, tty),
      onPermission: (evt, tty, signal) => this.onPermission(evt, tty, signal),
    });
  }

  /**
   * @param {{ gateway: import("../gateway.js").Gateway, brain: import("../brain.js").Brain,
   *           voice: import("../voice.js").VoiceService, permissions: import("../permissions.js").Permissions }} deps
   */
  init({ gateway, brain, voice, permissions }) {
    Object.assign(this, { gateway, brain, voice, permissions });
    this.sessions.on((event, s, evt) => {
      // Narrator first: it stays quiet for driven sessions, and the driver may end the drive.
      this.narrator.onEvent(event, s, evt);
      this.driver.onEvent(event, s, evt);
      this.gateway.broadcast("mercy:claude", this.state(), { to: ["panel"] });
    });
    gateway.handleAll({
      "mercy:claudeState": () => this.state(),
      "mercy:setClaude": ({ connected, announce } = {}) => {
        if (typeof announce === "boolean") store.set("claude", { ...this.prefs(), announce });
        if (connected === true) installHooks();
        if (connected === false) uninstallHooks();
        return this.state();
      },
    });
    return this;
  }

  async start() {
    await this.bridge.start();
    // Mercy moved (dev ↔ installed app): point the hooks at this copy.
    if (this.hooksState() === "stale") installHooks();
  }

  stop() {
    this.bridge.stop();
  }

  prefs() {
    return { announce: true, ...(store.get("claude") ?? {}) };
  }

  hooksState() {
    try {
      return hooksState();
    } catch (err) {
      log.warn(`[claude] ${err.message}`);
      return "off";
    }
  }

  state() {
    return {
      connected: this.hooksState() !== "off",
      announce: this.prefs().announce,
      sessions: this.sessions.list().map((s) => ({ id: s.id, name: s.name, status: s.status, activity: s.activity, goal: s.goal?.text ?? null })),
    };
  }

  /** claude_connect: the user approves, then the hooks go in. */
  async connect(ctx) {
    if (this.hooksState() === "on") return { ok: true, already: true };
    const decision = await ctx?.permissions?.request(
      {
        kind: "claude",
        title: "Connect Claude Code to Mercy",
        detail: "Adds Mercy's hooks to ~/.claude/settings.json (your other settings stay as they are; a backup is kept).",
        risky: true,
        spoken: "Should I connect to Claude Code? Say yes or no.",
      },
      ctx.signal,
    );
    if (decision !== "allow") return { ok: false, denied: true, error: "The user didn't connect Claude Code." };
    installHooks();
    this.gateway.broadcast("mercy:claude", this.state(), { to: ["panel"] });
    return { ok: true, note: "Connected. Claude windows that were already open need a restart (or /hooks) before Mercy sees them." };
  }

  /** A PermissionRequest from a session: ask the user (or decide, at "Just do it"). null → Claude asks in its terminal. */
  async onPermission(evt, tty, gone) {
    if (this.permissions.settings().trust.claude === "off") return null;
    const s = this.sessions.get(evt.session_id);
    const name = s ? this.sessions.nameOf(s) : path.basename(evt.cwd ?? "") || "Claude";
    const tool = evt.tool_name ?? "";
    const input = evt.tool_input ?? {};
    const what = describeTool(tool, input);
    const command = tool === "Bash" ? String(input.command ?? "") : "";
    const inProject = Boolean(input.file_path && s && path.resolve(s.cwd, input.file_path).startsWith(s.cwd + path.sep));
    const safe = READ_ONLY.has(tool) || (EDITS.has(tool) && inProject) || (tool === "Bash" && !riskyCommand(command));

    let always = {};
    const program = command && simpleProgram(command);
    if (program) always = { alwaysKey: `claude:bash:${program}`, alwaysLabel: `Always let Claude run ${program}` };
    else if (EDITS.has(tool) && inProject) always = { alwaysKey: `claude:edit:${s.cwd}`, alwaysLabel: `Always let Claude edit ${s.project}` };
    else if (tool && tool !== "Bash") always = { alwaysKey: `claude:tool:${tool}`, alwaysLabel: `Always let Claude use ${tool}` };

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), ANSWER_WITHIN_MS);
    gone.addEventListener("abort", () => ctrl.abort(), { once: true });
    const decision = await this.permissions.request(
      {
        kind: "claude",
        title: `Claude (${name}) is asking: ${what}`,
        detail: command || input.file_path || JSON.stringify(input, null, 1).slice(0, 600),
        why: input.description,
        risky: !safe,
        spoken: `Claude in ${name} is asking for permission: ${what}. Allow it?`,
        ...always,
      },
      ctrl.signal,
    );
    clearTimeout(timer);
    if (ctrl.signal.aborted) {
      log.info(`[claude] no answer for ${name}: ${what} → left to its terminal`);
      return null;
    }
    if (s) {
      s.status = decision === "allow" ? "working" : "idle";
      this.gateway.broadcast("mercy:claude", this.state(), { to: ["panel"] });
    }
    log.info(`[claude] ${name}: ${what} → ${decision}`);
    return {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: decision === "allow" ? { behavior: "allow" } : { behavior: "deny", message: "The user said no (through Mercy)." },
      },
    };
  }
}

export const claude = new ClaudeService();
