// Ask-before-acting: general tools (shell, AppleScript, Messages) call request()
// and wait for the user to answer in the panel (Allow once / Always / Deny) or
// by voice ("yes"/"no", spoken or typed). Unanswered requests are denied after a
// timeout.
//
// How much Mercy is trusted is the user's call, per kind of action (panel →
// ··· → Permissions):
//   ask   ask every time (things marked "Always allow" don't ask)
//   auto  just do it — except risky ones (deleting, killing, shutting down…),
//         which still ask
//   off   never; Mercy is told it's turned off
import crypto from "node:crypto";
import { store } from "./store.js";
import { log } from "./log.js";

const TIMEOUT_MS = 120000;
const YES = /^(yes|yeah|yep|yup|sure|ok(ay)?|do it|go ahead|allow( it)?|approved?|please do|go for it)\b/i;
const NO = /^(no|nope|nah|don'?t|do not|cancel|stop|deny|never mind|nevermind)\b/i;

/** Kinds of actions with their own trust setting, and the default. */
// claude: Claude Code asking for permission (claude/index.js) — "auto" lets
// Mercy approve the safe ones, "off" leaves them to Claude's own terminal prompt.
export const KINDS = { shell: "ask", applescript: "ask", message: "ask", claude: "ask" };
const LEVELS = new Set(["ask", "auto", "off"]);

export class Permissions {
  /** @param {import("./gateway.js").Gateway} gateway */
  constructor(gateway) {
    this.gateway = gateway;
    this.pending = new Map(); // id -> { resolve, timer, alwaysKey }
    this.listeners = new Set();
  }

  register() {
    this.gateway.handleAll({
      "mercy:permissionReply": ({ id, decision } = {}) => this.reply(id, decision),
      "mercy:getTrust": () => this.settings(),
      "mercy:setTrust": ({ kind, level } = {}) => {
        if (kind in KINDS && LEVELS.has(level)) this.save({ trust: { ...this.settings().trust, [kind]: level } });
        return this.settings();
      },
      "mercy:forgetAlways": (key) => {
        this.save({ always: this.settings().always.filter((k) => k !== key) });
        return this.settings();
      },
    });
  }

  /** Called with true when a request opens, false when none are left. */
  onPendingChange(cb) {
    this.listeners.add(cb);
  }

  /** { trust: { shell, applescript, message }, always: [...] } */
  settings() {
    const p = store.get("permissions") ?? {};
    const trust = Object.fromEntries(Object.entries(KINDS).map(([k, d]) => [k, LEVELS.has(p.trust?.[k]) ? p.trust[k] : d]));
    return { trust, always: p.always ?? [] };
  }

  save(patch) {
    store.set("permissions", { ...(store.get("permissions") ?? {}), ...patch });
  }

  isAlwaysAllowed(key) {
    return Boolean(key) && this.settings().always.includes(key);
  }

  /**
   * @param {{ kind: string, title: string, detail: string, why?: string, risky?: boolean, alwaysKey?: string, alwaysLabel?: string, spoken?: string }} req
   *   risky: asks even when the kind is set to "auto"
   *   spoken: what Mercy says out loud while it waits (default: a generic "say yes or no")
   * @param {AbortSignal} [signal] turn signal: an interrupted turn denies its request
   * @returns {Promise<"allow" | "deny" | "off">}
   */
  request(req, signal) {
    const level = this.settings().trust[req.kind] ?? "ask";
    if (level === "off") {
      log.info(`[perm] ${req.kind} is turned off → ${req.title}`);
      return Promise.resolve("off");
    }
    if (level === "auto" && !req.risky) {
      log.info(`[perm] auto-allowed: ${req.title} — ${req.detail.slice(0, 120)}`);
      return Promise.resolve("allow");
    }
    if (!req.risky && this.isAlwaysAllowed(req.alwaysKey)) return Promise.resolve("allow");
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => this.reply(id, "deny", "timed out"), TIMEOUT_MS);
      this.pending.set(id, { resolve, timer, alwaysKey: req.alwaysKey, spoken: req.spoken });
      signal?.addEventListener("abort", () => this.reply(id, "deny", "cancelled"), { once: true });
      this.showPanel?.(); // permission cards must be seen: open the panel
      this.gateway.broadcast("mercy:permission", { id, ...req }, { to: ["panel"] });
      log.info(`[perm] ask ${id.slice(0, 8)}: ${req.title} — ${req.detail.slice(0, 120)}`);
      this.emitPending();
    });
  }

  reply(id, decision, reason = "") {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    clearTimeout(p.timer);
    const d = decision === "always" && p.alwaysKey ? "always" : decision === "allow" || decision === "always" ? "allow" : "deny";
    if (d === "always") this.save({ always: [...new Set([...this.settings().always, p.alwaysKey])] });
    log.info(`[perm] ${id.slice(0, 8)} → ${d}${reason ? ` (${reason})` : ""}`);
    this.gateway.broadcast("mercy:permission:closed", { id, decision: d, reason }, { to: ["panel"] });
    p.resolve(d);
    this.emitPending();
  }

  /** A spoken answer while a request is open. Returns true if it was consumed. */
  answerByVoice(text) {
    const id = [...this.pending.keys()].at(-1);
    if (!id) return false;
    const t = text.trim().replace(/^(hey |ok |um |uh )?(mercy,? )?/i, "");
    if (YES.test(t)) this.reply(id, "allow", "voice");
    else if (NO.test(t)) this.reply(id, "deny", "voice");
    else return false;
    return true;
  }

  /** The newest open request, if any. */
  latest() {
    return [...this.pending.values()].at(-1) ?? null;
  }

  emitPending() {
    for (const cb of this.listeners) cb(this.pending.size > 0);
  }
}
