// "Halo x.y is out": checks GitHub Releases once a day (installed app only)
// and tells the panel. No auto-install — the app isn't signed with an Apple
// Developer ID, so updating means downloading the new DMG.
import { app, shell } from "electron";
import { PACKAGED } from "./paths.js";
import { log } from "./log.js";

const REPO = "Rashid0312/halo";
const DAY_MS = 24 * 60 * 60 * 1000;

/** "1.2.10" > "1.2.9" */
function newer(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0);
  }
  return false;
}

export class UpdateService {
  /** @param {import("./gateway.js").Gateway} gateway */
  constructor(gateway) {
    this.gateway = gateway;
    this.latest = null; // { version, url } when a newer release exists
  }

  register() {
    this.gateway.handleAll({
      "halo:updateInfo": () => this.latest,
      "halo:openUpdate": () => this.latest && shell.openExternal(this.latest.url),
    });
    if (!PACKAGED && !process.env.HALO_CHECK_UPDATES) return;
    setTimeout(() => this.check(), 10000);
    setInterval(() => this.check(), DAY_MS);
  }

  async check() {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
        headers: { "User-Agent": `Halo/${app.getVersion()}`, Accept: "application/vnd.github+json" },
      });
      if (!res.ok) return; // no releases yet, rate limit, offline…
      const rel = await res.json();
      const version = String(rel.tag_name ?? "").replace(/^v/, "");
      if (!version || !newer(version, app.getVersion())) return;
      this.latest = { version, url: rel.html_url };
      log.info(`[update] Halo ${version} is available`);
      this.gateway.broadcast("halo:update", this.latest, { to: ["panel"] });
    } catch (err) {
      log.debug(`[update] check failed: ${err.message}`);
    }
  }
}
