// Ask-before-acting: general tools (shell, AppleScript) call request() and wait
// for the user to answer in the panel (Allow once / Always / Deny) or by voice
// ("yes"/"no", spoken or typed). Unanswered requests are denied after a timeout.
import crypto from "node:crypto";
import { store } from "./store.js";
import { log } from "./log.js";

const TIMEOUT_MS = 120000;
const YES = /^(yes|yeah|yep|yup|sure|ok(ay)?|do it|go ahead|allow( it)?|approved?|please do|go for it)\b/i;
const NO = /^(no|nope|nah|don'?t|do not|cancel|stop|deny|never mind|nevermind)\b/i;

export class Permissions {
  /** @param {import("./gateway.js").Gateway} gateway */
  constructor(gateway) {
    this.gateway = gateway;
    this.pending = new Map(); // id -> { resolve, timer, alwaysKey }
    this.listeners = new Set();
  }

  register() {
    this.gateway.handle("halo:permissionReply", ({ id, decision } = {}) => this.reply(id, decision));
  }

  /** Called with true when a request opens, false when none are left. */
  onPendingChange(cb) {
    this.listeners.add(cb);
  }

  isAlwaysAllowed(key) {
    return Boolean(key) && (store.get("permissions")?.always ?? []).includes(key);
  }

  /**
   * @param {{ title: string, detail: string, why?: string, alwaysKey?: string, alwaysLabel?: string }} req
   * @param {AbortSignal} [signal] turn signal: an interrupted turn denies its request
   * @returns {Promise<"allow" | "always" | "deny">}
   */
  request(req, signal) {
    if (this.isAlwaysAllowed(req.alwaysKey)) return Promise.resolve("allow");
    const id = crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => this.reply(id, "deny", "timed out"), TIMEOUT_MS);
      this.pending.set(id, { resolve, timer, alwaysKey: req.alwaysKey });
      signal?.addEventListener("abort", () => this.reply(id, "deny", "cancelled"), { once: true });
      this.showPanel?.(); // permission cards must be seen: open the panel
      this.gateway.broadcast("halo:permission", { id, ...req }, { to: ["panel"] });
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
    if (d === "always") {
      const perms = store.get("permissions") ?? { always: [] };
      store.set("permissions", { ...perms, always: [...new Set([...(perms.always ?? []), p.alwaysKey])] });
    }
    log.info(`[perm] ${id.slice(0, 8)} → ${d}${reason ? ` (${reason})` : ""}`);
    this.gateway.broadcast("halo:permission:closed", { id, decision: d, reason }, { to: ["panel"] });
    p.resolve(d);
    this.emitPending();
  }

  /** A spoken answer while a request is open. Returns true if it was consumed. */
  answerByVoice(text) {
    const id = [...this.pending.keys()].at(-1);
    if (!id) return false;
    const t = text.trim().replace(/^(hey |ok |um |uh )?(halo,? )?/i, "");
    if (YES.test(t)) this.reply(id, "allow", "voice");
    else if (NO.test(t)) this.reply(id, "deny", "voice");
    else return false;
    return true;
  }

  emitPending() {
    for (const cb of this.listeners) cb(this.pending.size > 0);
  }
}
