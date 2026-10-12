// The user's own API keys (Deepgram for voice, DeepSeek for the brain),
// encrypted with the macOS Keychain (Electron safeStorage) in userData/keys.bin.
// In development a .env file still works as a fallback.
import { app, safeStorage, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { log } from "./log.js";

const ENV = { deepgram: "DEEPGRAM_API_KEY", deepseek: "DEEPSEEK_API_KEY" };
const CONSOLES = {
  deepgram: "https://console.deepgram.com/",
  deepseek: "https://platform.deepseek.com/api_keys",
};

let saved = {}; // { deepgram?, deepseek? }

function file() {
  return path.join(app.getPath("userData"), "keys.bin");
}

export async function loadKeys() {
  if (!fs.existsSync(file())) return;
  try {
    const { result, shouldReEncrypt } = await safeStorage.decryptStringAsync(fs.readFileSync(file()));
    saved = JSON.parse(result);
    if (shouldReEncrypt) await persist();
  } catch (err) {
    log.error(`[keys] could not read saved keys: ${err.message}`);
    saved = {};
  }
}

async function persist() {
  const enc = await safeStorage.encryptStringAsync(JSON.stringify(saved));
  fs.writeFileSync(file(), enc, { mode: 0o600 });
}

/** @param {"deepgram" | "deepseek"} name */
export function getKey(name) {
  return saved[name] || process.env[ENV[name]] || "";
}

export function keysState() {
  const has = (n) => Boolean(getKey(n));
  return { deepgram: has("deepgram"), deepseek: has("deepseek"), ready: has("deepgram") && has("deepseek") };
}

/** Check a key against its service. Resolves to an error message, or "" if it works. */
async function check(name, key) {
  const req =
    name === "deepgram"
      ? fetch("https://api.deepgram.com/v1/projects", { headers: { Authorization: `Token ${key}` } })
      : fetch("https://api.deepseek.com/models", { headers: { Authorization: `Bearer ${key}` } });
  try {
    const res = await req;
    if (res.ok) return "";
    if (res.status === 401 || res.status === 403) return "That key wasn't accepted — check you copied all of it.";
    return `The service answered ${res.status}. Try again in a moment.`;
  } catch {
    return "Couldn't reach the service — are you online?";
  }
}

export function registerKeys(gateway) {
  gateway.handleAll({
    "mercy:keysState": () => keysState(),
    /** @param {{ deepgram?: string, deepseek?: string }} input — blank fields keep the current key */
    "mercy:setKeys": async (input = {}) => {
      const errors = {};
      const next = { ...saved };
      for (const name of ["deepgram", "deepseek"]) {
        const key = String(input[name] ?? "").trim();
        if (!key) continue;
        const problem = await check(name, key);
        if (problem) errors[name] = problem;
        else next[name] = key;
      }
      if (Object.keys(errors).length) return { ok: false, errors, ...keysState() };
      saved = next;
      await persist();
      log.info(`[keys] saved (${Object.keys(saved).join(", ")})`); // names only, never values
      return { ok: true, errors: {}, ...keysState() };
    },
    "mercy:openKeyConsole": (name) => CONSOLES[name] && shell.openExternal(CONSOLES[name]),
  });
}
