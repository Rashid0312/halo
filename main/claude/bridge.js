// Where Claude Code's hooks reach Mercy: a small HTTP server on 127.0.0.1.
// claude-hook.sh finds it through <userData>/claude-bridge ("<port> <token>").
//
//   POST /event       a hook event, answered at once
//   POST /permission  a PermissionRequest, held open until there's a decision
//                     (or none: then Claude asks in its terminal as usual)
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { app } from "electron";
import { log } from "../log.js";

const MAX_BODY = 1024 * 1024;

export const bridgeFile = () => path.join(app.getPath("userData"), "claude-bridge");

export class Bridge {
  /**
   * @param {{ onEvent: (evt: object, tty: string) => void,
   *           onPermission: (evt: object, tty: string, signal: AbortSignal) => Promise<object | null> }} handlers
   */
  constructor(handlers) {
    this.handlers = handlers;
    this.token = crypto.randomBytes(24).toString("hex");
    this.server = null;
  }

  start() {
    this.server = http.createServer((req, res) => this.handle(req, res).catch((err) => {
      log.error(`[claude] bridge: ${err.stack ?? err}`);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    }));
    return new Promise((resolve, reject) => {
      this.server.once("error", reject);
      this.server.listen(0, "127.0.0.1", () => {
        const { port } = this.server.address();
        fs.writeFileSync(bridgeFile(), `${port} ${this.token}\n`, { mode: 0o600 });
        log.info(`[claude] bridge on 127.0.0.1:${port}`);
        resolve(port);
      });
    });
  }

  stop() {
    this.server?.close();
    this.server = null;
    fs.rmSync(bridgeFile(), { force: true });
  }

  async handle(req, res) {
    const auth = req.headers.authorization ?? "";
    const expected = `Bearer ${this.token}`;
    if (req.method !== "POST" || auth.length !== expected.length || !crypto.timingSafeEqual(Buffer.from(auth), Buffer.from(expected))) {
      res.writeHead(403);
      return res.end();
    }
    let body = "";
    for await (const chunk of req) {
      body += chunk;
      if (body.length > MAX_BODY) {
        res.writeHead(413);
        return res.end();
      }
    }
    let evt;
    try {
      evt = JSON.parse(body);
    } catch {
      res.writeHead(400);
      return res.end();
    }
    const raw = String(req.headers["x-claude-tty"] ?? "").trim();
    const tty = /^ttys?\d+$/.test(raw) ? `/dev/${raw}` : "";

    if (req.url === "/event") {
      res.writeHead(204);
      res.end();
      this.handlers.onEvent(evt, tty);
      return;
    }
    if (req.url === "/permission") {
      this.handlers.onEvent(evt, tty);
      // The hook gave up (its curl timed out): stop asking.
      const gone = new AbortController();
      res.on("close", () => gone.abort());
      const decision = await this.handlers.onPermission(evt, tty, gone.signal);
      if (gone.signal.aborted) return;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(decision ? JSON.stringify(decision) : "");
      return;
    }
    res.writeHead(404);
    res.end();
  }
}
