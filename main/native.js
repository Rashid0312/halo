// Small Swift helpers in native/<name>/ (Touch Bar button, on-device speech).
// Installed app: prebuilt in Contents/Resources. Development: compiled next to
// their source on first use, and again whenever the source is newer.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { PACKAGED, RESOURCES, ROOT } from "./paths.js";
import { log } from "./log.js";

/** Where the helper `binary` from native/`dir` lives. */
export function helperPath(dir, binary) {
  return PACKAGED ? path.join(RESOURCES, binary) : path.join(ROOT, "native", dir, binary);
}

const building = new Map(); // binary → Promise, so two callers don't compile at once

/**
 * Compile the helper if it's missing or older than its source. Resolves to its path.
 * @param {string} dir     folder under native/, e.g. "touchbar"
 * @param {string} source  Swift file in that folder
 * @param {string} binary  executable name, e.g. "mercy-touchbar"
 */
export function buildHelper(dir, source, binary) {
  const out = helperPath(dir, binary);
  if (PACKAGED) {
    if (!fs.existsSync(out)) return Promise.reject(new Error("helper missing from the app bundle"));
    return Promise.resolve(out);
  }
  const src = path.join(ROOT, "native", dir, source);
  if (fs.existsSync(out) && fs.statSync(out).mtimeMs >= fs.statSync(src).mtimeMs) return Promise.resolve(out);
  if (!building.has(out)) {
    log.info(`[native] building ${binary}…`);
    const job = promisify(execFile)("swiftc", ["-O", src, "-o", out], { timeout: 300000 })
      .then(() => out)
      .finally(() => building.delete(out));
    building.set(out, job);
  }
  return building.get(out);
}
