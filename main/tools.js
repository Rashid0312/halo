// Tools the brain can call: open/quit apps, URLs, Calendar, Reminders, Notes,
// Shortcuts. Each tool is an OpenAI-style function definition plus a runner
// that returns a short JSON-able result for the model.
//
// The specific tools never delete data. Mac app access goes through JXA
// (main/mac/*.jxa); macOS asks once per app ("Halo wants to control Calendar").
// The general tools (run_shell, run_applescript) can do anything, so every
// call asks the user first (permissions.js) unless they chose "Always allow".
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { UNPACKED } from "./paths.js";
import { log } from "./log.js";

const run = promisify(execFile);
const TIMEOUT_MS = 20000;

async function jxa(script, ...args) {
  const { stdout } = await run("osascript", ["-l", "JavaScript", path.join(UNPACKED, "main", "mac", script), ...args.map((a) => String(a ?? ""))], {
    timeout: TIMEOUT_MS,
  });
  return JSON.parse(stdout.trim() || "null");
}

// ── app lookup ─────────────────────────────────────────────────────────
const APP_DIRS = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", path.join(os.homedir(), "Applications")];
const NOT_LAUNCHABLE = /\b(helper|url handler|uninstall|agent)\b/i;

function installedApps() {
  const apps = [];
  for (const dir of APP_DIRS) {
    let entries = [];
    try {
      entries = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.endsWith(".app")) apps.push({ name: e.slice(0, -4), path: path.join(dir, e) });
    }
  }
  return apps;
}

const norm = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const ALIASES = {
  vscode: "visual studio code",
  "vs code": "visual studio code",
  code: "visual studio code",
  chrome: "google chrome",
  settings: "system settings",
  "system preferences": "system settings",
  teams: "microsoft teams",
  word: "microsoft word",
  excel: "microsoft excel",
  powerpoint: "microsoft powerpoint",
  outlook: "microsoft outlook",
};

/** Best installed app for a spoken name ("visual studio" → Visual Studio Code). */
export function findApp(query, apps = installedApps()) {
  const q = ALIASES[norm(query)] ?? norm(query);
  if (!q) return null;
  let best = null;
  for (const app of apps) {
    const n = norm(app.name);
    let score = 0;
    if (n === q) score = 100;
    else if (n.startsWith(q + " ")) score = 80;
    else if (n.split(" ").includes(q)) score = 60;
    else if (n.includes(q)) score = 40;
    else if (q.split(" ").every((w) => n.includes(w))) score = 30;
    if (!score || NOT_LAUNCHABLE.test(app.name)) continue;
    score -= n.length / 100; // prefer the shorter, more canonical name
    if (!best || score > best.score) best = { ...app, score };
  }
  return best && best.score > 10 ? best : null;
}

// ── general tools: safety rails ────────────────────────────────────────
const OUTPUT_CHARS = 4000;
// Never run, even if approved.
const BLOCKED = [
  [/(^|[\s;&|(])sudo\b/, "sudo isn't allowed (Halo can't type your password)."],
  [/\brm\s+(-[a-z]*\s+)*(-[a-z]*[rf][a-z]*\s+)+(\/|~|\$HOME)\/?(\s|$|\*)/i, "Deleting your whole disk or home folder isn't allowed."],
  [/\b(mkfs|diskutil\s+(erase|partition|zero))/i, "Disk formatting isn't allowed."],
  [/:\(\)\s*\{\s*:\|:&\s*\};:/, "Fork bombs aren't allowed."],
];
// Programs that can never be "always allowed": each use is asked about.
const ALWAYS_ASK = new Set(
  "rm rmdir mv dd chmod chown kill killall pkill shutdown reboot halt launchctl defaults diskutil curl wget ssh scp rsync sh bash zsh fish python python3 node ruby perl osascript open eval exec xargs find git npm npx pip pip3 brew crontab security".split(" "),
);
// Strip secrets from anything Halo runs.
const childEnv = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !/KEY|TOKEN|SECRET|PASSWORD/i.test(k)));

function firstProgram(command) {
  const m = command.trim().match(/^(?:\w+=\S*\s+)*([^\s;&|()]+)/);
  return m ? path.basename(m[1]) : "";
}

const clip = (s) => (s.length > OUTPUT_CHARS ? s.slice(0, OUTPUT_CHARS) + `\n…(${s.length - OUTPUT_CHARS} more chars)` : s);

async function ask(ctx, req) {
  if (!ctx?.permissions) return "deny";
  return ctx.permissions.request(req, ctx.signal);
}

// ── tool definitions ───────────────────────────────────────────────────
const fn = (name, description, properties = {}, required = []) => ({
  type: "function",
  function: { name, description, parameters: { type: "object", properties, required } },
});
const str = (description) => ({ type: "string", description });

const TOOLS = {
  open_app: {
    def: fn("open_app", "Open (or bring to front) an application on the user's Mac.", { name: str("App name as the user said it, e.g. 'Visual Studio', 'Spotify'") }, ["name"]),
    async run({ name }) {
      const app = findApp(name);
      if (!app) return { ok: false, error: `No installed app matches "${name}".` };
      await run("open", ["-a", app.path], { timeout: TIMEOUT_MS });
      return { ok: true, opened: app.name };
    },
  },
  quit_app: {
    def: fn("quit_app", "Quit a running application. The app itself asks about unsaved work.", { name: str("App name") }, ["name"]),
    async run({ name }) {
      const app = findApp(name);
      if (!app) return { ok: false, error: `No installed app matches "${name}".` };
      return { ...(await jxa("app-quit.jxa", app.name)), app: app.name };
    },
  },
  open_url: {
    def: fn("open_url", "Open a website or URL in the default browser. Use a search URL for 'search for …'.", { url: str("Full URL including https://") }, ["url"]),
    async run({ url }) {
      if (!/^https?:\/\//i.test(url)) return { ok: false, error: "Only http(s) URLs are allowed." };
      await run("open", [url], { timeout: TIMEOUT_MS });
      return { ok: true };
    },
  },
  calendar_events: {
    def: fn(
      "calendar_events",
      "List the user's Calendar events. Recurring events may only show their first occurrence.",
      { from: str("Start date, YYYY-MM-DD (local)"), days: { type: "integer", description: "How many days from `from` (default 1)" } },
      ["from"],
    ),
    run: ({ from, days = 1 }) => jxa("calendar-list.jxa", from, days),
  },
  calendar_create: {
    def: fn(
      "calendar_create",
      "Create a Calendar event.",
      {
        title: str("Event title"),
        start: str("Local start time, YYYY-MM-DDTHH:MM:SS (no timezone)"),
        end: str("Local end time, same format. Default to one hour after start."),
        calendar: str("Calendar name (optional)"),
        notes: str("Notes (optional)"),
      },
      ["title", "start", "end"],
    ),
    run: ({ title, start, end, calendar, notes }) => jxa("calendar-create.jxa", title, start, end, calendar, notes),
  },
  reminders_add: {
    def: fn(
      "reminders_add",
      "Add a reminder to the Reminders app.",
      { title: str("What to be reminded of"), due: str("Local due time YYYY-MM-DDTHH:MM:SS (optional)"), list: str("List name (optional)") },
      ["title"],
    ),
    run: ({ title, due, list }) => jxa("reminders-add.jxa", title, due, list),
  },
  notes_create: {
    def: fn("notes_create", "Create a note in the Notes app.", { title: str("Note title"), body: str("Note text, plain lines") }, ["title"]),
    run: ({ title, body }) => jxa("notes-create.jxa", title, body),
  },
  shortcuts_list: {
    def: fn("shortcuts_list", "List the user's Shortcuts (from the Shortcuts app)."),
    async run() {
      const { stdout } = await run("shortcuts", ["list"], { timeout: TIMEOUT_MS });
      return { shortcuts: stdout.split("\n").filter(Boolean) };
    },
  },
  shortcut_run: {
    def: fn("shortcut_run", "Run one of the user's Shortcuts by exact name.", { name: str("Shortcut name"), input: str("Text input (optional)") }, ["name"]),
    async run({ name, input }) {
      const args = ["run", name];
      let tmp = null;
      if (input) {
        tmp = path.join(os.tmpdir(), `halo-shortcut-${Date.now()}.txt`);
        fs.writeFileSync(tmp, input);
        args.push("--input-path", tmp);
      }
      try {
        const { stdout } = await run("shortcuts", args, { timeout: 60000 });
        return { ok: true, output: stdout.trim().slice(0, 2000) };
      } finally {
        if (tmp) fs.rm(tmp, { force: true }, () => {});
      }
    },
  },
};

// Apps that can act as the user (send, type, run anything): every script asks.
const NEVER_ALWAYS_APPS = /^(messages|mail|terminal|iterm2?|system events|contacts|finder|script editor|shortcuts)$/i;

TOOLS.contacts_find = {
  def: fn("contacts_find", "Look up people in the user's Contacts by name; returns their phone numbers and emails.", { name: str("Name or part of a name") }, ["name"]),
  run: ({ name }) => jxa("contacts-find.jxa", name),
};

const looksLikeHandle = (s) => /^\S+@\S+\.\S+$/.test(s) || /^\+?[\d\s().-]{7,}$/.test(s.trim());

/** Pick the best handle for a contact: iPhone/mobile number, then any number, then email. */
function bestHandle(person) {
  const phones = person.phones ?? [];
  const mobile = phones.find((p) => /iphone|mobile|cell/i.test(p.label));
  return (mobile ?? phones[0] ?? person.emails?.[0])?.value ?? null;
}

TOOLS.messages_send = {
  def: fn(
    "messages_send",
    "Send an iMessage/SMS from the user's Messages app. `to` can be a contact name, phone number or email. The user always sees the recipient and exact text and must approve before it sends. If several contacts match, ask the user which one and call again with their number.",
    { to: str("Contact name, phone number, or email"), text: str("The exact message to send") },
    ["to", "text"],
  ),
  async run({ to, text }, ctx) {
    to = String(to ?? "").trim();
    text = String(text ?? "").trim();
    if (!to || !text) return { ok: false, error: "Need both a recipient and a message." };
    let name = to;
    let handle = looksLikeHandle(to) ? to.trim() : null;
    if (!handle) {
      const people = (await jxa("contacts-find.jxa", to)) ?? [];
      const reachable = people.filter((p) => bestHandle(p));
      if (!reachable.length) return { ok: false, error: `No contact named "${to}" with a phone number or email.` };
      if (reachable.length > 1) {
        return {
          ok: false,
          ambiguous: true,
          error: `Several contacts match "${to}". Ask the user which one.`,
          matches: reachable.map((p) => ({ name: p.name, phones: p.phones.map((x) => x.value), emails: p.emails.map((x) => x.value) })),
        };
      }
      name = reachable[0].name;
      handle = bestHandle(reachable[0]);
    }
    const decision = await ask(ctx, {
      kind: "message",
      title: `Send a message to ${name === handle ? handle : `${name} (${handle})`}`,
      detail: text,
      allowLabel: "Send",
      alwaysKey: `messages:${handle}`,
      alwaysLabel: `Always allow messages to ${name}`,
    });
    if (decision === "deny") return { ok: false, denied: true, error: "The user chose not to send it." };
    const { stdout } = await run("osascript", [path.join(UNPACKED, "main", "mac", "messages-send.applescript"), handle, text], {
      env: childEnv(),
      timeout: TIMEOUT_MS,
    });
    return {
      ok: true,
      to: name,
      handle,
      via: stdout.trim() === "sms" ? "SMS" : "iMessage",
      note: "Messages accepted it. If delivery fails, Messages shows an alert — tell the user to check there.",
    };
  },
};

TOOLS.run_shell = {
  def: fn(
    "run_shell",
    "Run a zsh command on the user's Mac (cwd: home folder). Use for anything no specific tool covers: files, folders, git, system info, installing, scripts, launching CLIs. The user approves each command first. Prefer one clear command; chain with && when needed.",
    {
      command: str("The exact zsh command"),
      why: str("One short sentence the user sees explaining what this does"),
      cwd: str("Working directory (optional, default ~)"),
    },
    ["command", "why"],
  ),
  async run({ command, why, cwd }, ctx) {
    for (const [re, msg] of BLOCKED) if (re.test(command)) return { ok: false, error: msg };
    const program = firstProgram(command);
    const simple = program && !ALWAYS_ASK.has(program) && !/[;&|`$<>]/.test(command);
    const decision = await ask(ctx, {
      kind: "shell",
      title: "Run a command",
      detail: command,
      why,
      ...(simple ? { alwaysKey: `shell:${program}`, alwaysLabel: `Always allow ${program}` } : {}),
    });
    if (decision === "deny") return { ok: false, denied: true, error: "The user said no." };
    const dir = cwd ? cwd.replace(/^~(?=$|\/)/, os.homedir()) : os.homedir();
    try {
      const { stdout, stderr } = await run("/bin/zsh", ["-lc", command], { cwd: dir, env: childEnv(), timeout: 120000, maxBuffer: 8 * 1024 * 1024 });
      return { ok: true, stdout: clip(stdout), ...(stderr.trim() ? { stderr: clip(stderr) } : {}) };
    } catch (err) {
      return { ok: false, exitCode: err.code, stdout: clip(err.stdout ?? ""), stderr: clip(err.stderr ?? String(err.message)) };
    }
  },
};

TOOLS.run_applescript = {
  def: fn(
    "run_applescript",
    "Run AppleScript to control any scriptable Mac app or UI (Finder, Safari, Mail, Messages, Music, System Events, window management, clicking menus…). The user approves each script first.",
    { script: str("The AppleScript source"), why: str("One short sentence the user sees explaining what this does") },
    ["script", "why"],
  ),
  async run({ script, why }, ctx) {
    const apps = [...script.matchAll(/tell application "([^"]+)"/g)].map((m) => m[1]);
    // Messages goes through messages_send so the user always sees who and what.
    if (apps.some((a) => /^messages$/i.test(a))) {
      return { ok: false, error: "Use the messages_send tool to send messages, not AppleScript." };
    }
    const single =
      new Set(apps).size === 1 && !/do shell script/i.test(script) && !NEVER_ALWAYS_APPS.test(apps[0]) ? apps[0] : null;
    const decision = await ask(ctx, {
      kind: "applescript",
      title: single ? `Control ${single}` : "Run an AppleScript",
      detail: script,
      why,
      ...(single ? { alwaysKey: `applescript:${single}`, alwaysLabel: `Always allow ${single}` } : {}),
    });
    if (decision === "deny") return { ok: false, denied: true, error: "The user said no." };
    const { stdout } = await run("osascript", ["-e", script], { env: childEnv(), timeout: 60000 });
    return { ok: true, result: clip(stdout.trim()) };
  },
};

export const TOOL_DEFS = Object.values(TOOLS).map((t) => t.def);

/** Short present-tense label for the panel, e.g. "Opening Visual Studio". */
export function toolLabel(name, args = {}) {
  switch (name) {
    case "open_app":
      return `Opening ${args.name}`;
    case "quit_app":
      return `Quitting ${args.name}`;
    case "open_url":
      return `Opening ${args.url}`;
    case "calendar_events":
      return "Checking your calendar";
    case "calendar_create":
      return `Adding "${args.title}" to your calendar`;
    case "reminders_add":
      return `Adding reminder "${args.title}"`;
    case "notes_create":
      return `Creating note "${args.title}"`;
    case "shortcuts_list":
      return "Looking at your Shortcuts";
    case "shortcut_run":
      return `Running shortcut "${args.name}"`;
    case "contacts_find":
      return `Looking up ${args.name} in Contacts`;
    case "messages_send":
      return `Messaging ${args.to}`;
    case "run_shell":
    case "run_applescript":
      return args.why || (name === "run_shell" ? "Running a command" : "Running AppleScript");
    default:
      return name;
  }
}

/**
 * Run a tool call; always resolves to a JSON string for the model.
 * @param {{ permissions?: import("./permissions.js").Permissions, signal?: AbortSignal }} [ctx]
 */
export async function runTool(name, rawArgs, ctx = {}) {
  const tool = TOOLS[name];
  if (!tool) return JSON.stringify({ ok: false, error: `unknown tool ${name}` });
  let args = {};
  try {
    args = rawArgs ? JSON.parse(rawArgs) : {};
  } catch {
    return JSON.stringify({ ok: false, error: "arguments were not valid JSON" });
  }
  const started = Date.now();
  try {
    const result = await tool.run(args, ctx);
    log.info(`[tool] ${name} ${rawArgs} → ok (${Date.now() - started}ms)`);
    return JSON.stringify(result ?? { ok: true });
  } catch (err) {
    const message = String(err?.stderr || err?.message || err).trim().slice(0, 400);
    log.warn(`[tool] ${name} ${rawArgs} → ${message}`);
    // -1743: the user hasn't allowed Halo to control that app yet.
    const hint = /-1743|not authori[sz]ed/i.test(message)
      ? " The user needs to allow Halo in System Settings → Privacy & Security → Automation."
      : "";
    return JSON.stringify({ ok: false, error: message + hint });
  }
}
