// The brain: answers what the user asks (spoken or typed), calling tools to
// act on the Mac, and helps with what's on screen.
//
//   ask(text) ──► turn.started ──► (tool.started / tool.done)* + turn.token* ──► turn.done
//
// Frames go to the panel and voice via realtime.js; transcript frames from
// speech.js (role "user") fill in what was heard while listening.
import crypto from "node:crypto";
import { streamChat, imageContent, MODELS } from "./llm/deepseek.js";
import { TOOL_DEFS, runTool, toolLabel } from "./tools.js";
import { log } from "./log.js";

const HISTORY_LINES = 16;
const MAX_TOOL_STEPS = 10; // model → tools → model rounds per turn

export class Brain {
  /**
   * @param {import("./realtime.js").Realtime} realtime
   * @param {import("./session.js").SessionService} session
   * @param {import("./permissions.js").Permissions} permissions
   */
  constructor(realtime, session, permissions) {
    this.realtime = realtime;
    this.session = session;
    this.permissions = permissions;
    this.reset();
  }

  reset() {
    this.history = []; // [{ role: "user" | "assistant", text }]
    this.turn = null; // { id, controller }
    this.listening = false; // listening is open (voice.js)
    this.heard = []; // mic finals while listening
    this.interim = ""; // latest unfinished mic text while listening
  }

  register() {
    this.realtime.onFrame((frame) => {
      if (frame.type !== "transcript" || !this.listening) return;
      const { role, text, final } = frame.data;
      if (role !== "user") return;
      if (final) {
        this.heard.push(text);
        this.interim = "";
      } else this.interim = text;
    });
    this.session.onChange((snap) => {
      if (snap.status !== "active") {
        this.abortTurn();
        this.reset();
      }
    });
  }

  startListening({ keepTurn = false } = {}) {
    if (!keepTurn) this.abortTurn();
    this.listening = true;
    this.heard = [];
    this.interim = "";
  }

  /** Close listening (the caller has already finalized the transcript). */
  stopListening() {
    this.listening = false;
    const text = [...this.heard, this.interim].join(" ").replace(/\s+/g, " ").trim();
    this.heard = [];
    this.interim = "";
    return text;
  }

  /** Answer something the user said or typed. */
  ask(utterance) {
    log.info(`[ask] "${utterance}"`);
    this.pushHistory("user", utterance);
    return this.runTurn({
      model: MODELS.answer,
      messages: this.answerMessages(utterance),
      tools: TOOL_DEFS,
      source: "spoken",
      temperature: 0.5,
    });
  }

  /** "Look at my screen": screenshot(s) go straight to the vision model. */
  solveScreen(images) {
    return this.runTurn({ model: MODELS.vision, messages: this.solveMessages(images), source: "screen", maxTokens: 4000 });
  }

  pushHistory(role, text) {
    this.history.push({ role, text });
    if (this.history.length > HISTORY_LINES) this.history.shift();
  }

  abortTurn() {
    if (!this.turn) return;
    this.turn.controller.abort();
    this.realtime.emit({ type: "turn.superseded", data: { turn_id: this.turn.id } });
    this.turn = null;
  }

  async runTurn({ model, messages, tools, source, maxTokens = 2000, temperature }) {
    // A newer question cancels the stale answer instead of queueing behind it.
    this.abortTurn();
    const turn = { id: crypto.randomUUID(), controller: new AbortController() };
    this.turn = turn;
    this.realtime.emit({ type: "turn.started", data: { turn_id: turn.id, source } });

    const started = Date.now();
    let first = 0;
    let answer = "";
    try {
      const token = (delta) => {
        if (!first) first = Date.now() - started;
        answer += delta;
        this.realtime.emit({ type: "turn.token", data: { turn_id: turn.id, delta } });
      };
      let msgs = messages;
      for (let step = 0; step < MAX_TOOL_STEPS; step++) {
        let text = "";
        let calls = null;
        const opts = { model, messages: msgs, tools, maxTokens, temperature, signal: turn.controller.signal };
        for await (const ev of streamChat(opts)) {
          if (this.turn !== turn) return;
          if (ev.type === "text") {
            text += ev.delta;
            token(ev.delta);
          } else calls = ev.calls;
        }
        if (!calls?.length) break;
        // Keep any lead-in text ("Sure, opening it.") on its own line.
        if (text && !text.endsWith("\n")) token("\n\n");
        msgs = [
          ...msgs,
          { role: "assistant", content: text || null, tool_calls: calls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } })) },
        ];
        for (const call of calls) {
          let args = {};
          try {
            args = JSON.parse(call.arguments || "{}");
          } catch {}
          this.realtime.emit({ type: "tool.started", data: { turn_id: turn.id, call_id: call.id, name: call.name, label: toolLabel(call.name, args) } });
          const result = await runTool(call.name, call.arguments, { permissions: this.permissions, signal: turn.controller.signal });
          if (this.turn !== turn) return;
          const ok = !/"ok":false/.test(result);
          this.realtime.emit({ type: "tool.done", data: { turn_id: turn.id, call_id: call.id, name: call.name, ok } });
          msgs.push({ role: "tool", tool_call_id: call.id, content: result });
        }
      }
      if (this.turn !== turn) return;
      this.realtime.emit({ type: "turn.done", data: { turn_id: turn.id } });
      this.pushHistory("assistant", answer.slice(0, 600));
      log.info(`[turn:${source}] done first=${first}ms total=${Date.now() - started}ms chars=${answer.length}`);
    } catch (err) {
      if (turn.controller.signal.aborted) return;
      log.error(`[turn:${source}] ${err.message}`);
      this.realtime.emit({ type: "error", data: { code: "turn_failed", message: err.message, turnId: turn.id } });
    } finally {
      if (this.turn === turn) this.turn = null;
    }
  }

  solveMessages(images) {
    const lang = this.session.context?.codingLanguage || "Python";
    const system = [
      "You are Halo, a desktop assistant. The image is the user's screen.",
      "Figure out what the user is working on and help with it. Read text, code and error messages carefully from the image.",
      `- Code or an error: explain the problem in a sentence or two, then the fix as code (default ${lang}, or whatever language is on screen) in a fenced block.`,
      "- A document, email or form: summarize it or suggest what to write, whichever is more useful.",
      "- Anything else: answer directly and briefly.",
      "No preamble.",
    ].join("\n");
    const recent = this.history
      .slice(-4)
      .filter((l) => l.role === "user")
      .map((l) => `USER: ${l.text}`)
      .join("\n");
    return [
      { role: "system", content: system },
      {
        role: "user",
        content: imageContent(images, (recent ? `Recent conversation (may clarify the request):\n${recent}\n\n` : "") + "Help me with what's on my screen."),
      },
    ];
  }

  answerMessages(utterance) {
    const ctx = this.session.context ?? {};
    const now = new Date();
    const system = [
      "You are Halo, a friendly desktop assistant the user talks to by voice while they work on their Mac.",
      `Right now it is ${now.toLocaleString("en-US", { weekday: "long", year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit" })} (${Intl.DateTimeFormat().resolvedOptions().timeZone}). Today is ${now.toLocaleDateString("en-CA")}.`,
      "You can act on the user's Mac with your tools. Use the specific tools first (apps, websites, Calendar, Reminders, Notes, Shortcuts). For ANYTHING else, use run_shell (terminal commands) or run_applescript (control any app or the UI). Halo's permission settings decide whether the user approves a command first, so don't refuse and don't ask in chat whether you should: just call the tool with a clear `why`. If a tool says it's turned off, tell the user they can turn it on in ··· → Permissions.",
      "To text or iMessage someone, ALWAYS use messages_send (it looks the contact up and shows the user the exact text before sending). Never send messages any other way. Write the message exactly as the user wants it, without adding your own sign-off.",
      "Never say you can't access the user's computer, files or apps. Find a way with the tools. If the user denies a command, accept it and offer an alternative.",
      "Work step by step: look first (e.g. list files) before changing things. After acting, confirm in one short sentence what you did or what went wrong. Never use sudo.",
      // Replies are spoken: keep them short.
      "- Lead with the direct answer in one sentence, then 2-3 sentences of plain explanation if needed.",
      "- Short sentences and everyday words. No filler, no \"Great question\".",
      `- Code: a short explanation, then the code in ${ctx.codingLanguage || "Python"} (or the language the user mentions) in a fenced block.`,
      "- If the request is ambiguous, give the most likely answer and mention the assumption in a few words.",
      ctx.language && !ctx.language.startsWith("en") ? `Answer in the user's language (${ctx.language}).` : "",
    ]
      .filter(Boolean)
      .join("\n");

    const transcript = this.history
      .slice(0, -1)
      .map((l) => `${l.role === "assistant" ? "HALO" : "USER"}: ${l.text}`)
      .join("\n");

    return [
      { role: "system", content: system },
      { role: "user", content: (transcript ? `Conversation so far:\n${transcript}\n\n` : "") + `The user just said: "${utterance}"` },
    ];
  }
}
