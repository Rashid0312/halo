// Logging to the terminal and to ~/Library/Logs/Halo/halo.log (rotated at
// 5 MB to halo.1.log), since the installed app has no terminal.
import { app } from "electron";
import fs from "node:fs";
import path from "node:path";

const debug = process.env.HALO_DEBUG === "1";
const MAX_BYTES = 5 * 1024 * 1024;
let file = null;

export function logFile() {
  if (file) return file;
  try {
    const dir = process.env.HALO_USER_DATA ? path.join(process.env.HALO_USER_DATA, "logs") : app.getPath("logs");
    fs.mkdirSync(dir, { recursive: true });
    file = path.join(dir, "halo.log");
  } catch {
    file = null;
  }
  return file;
}

function write(level, args) {
  const f = logFile();
  if (!f) return;
  const text = args.map((a) => (a instanceof Error ? a.stack : typeof a === "string" ? a : JSON.stringify(a))).join(" ");
  try {
    if (fs.existsSync(f) && fs.statSync(f).size > MAX_BYTES) fs.renameSync(f, f.replace(/\.log$/, ".1.log"));
    fs.appendFileSync(f, `${new Date().toISOString()} ${level} ${text}\n`);
  } catch {
    // Logging must never take Halo down.
  }
}

export const log = {
  info: (...a) => (console.log(...a), write("INFO", a)),
  warn: (...a) => (console.warn(...a), write("WARN", a)),
  error: (...a) => (console.error(...a), write("ERROR", a)),
  debug: (...a) => {
    if (debug) (console.log(...a), write("DEBUG", a));
  },
};
