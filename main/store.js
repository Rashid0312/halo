// Tiny JSON-file store for Mercy's settings (userData/store.json).
import { app } from "electron";
import fs from "node:fs";
import path from "node:path";

const DEFAULTS = {
  userPrefs: { language: "en-US", coding_language: "Python" },
  // "Hey Mercy": on by default, starts once the user has enrolled their voice.
  wake: { enabled: true, followUpMs: 6000 },
  permissions: { always: [] }, // "shell:git", "applescript:Finder" — see permissions.js
  voice: { enabled: true, model: "aura-2-andromeda-en" },
  stt: { engine: "deepgram" }, // "deepgram" | "apple" | "auto" — see speech.js
  ui: {},
};

class Store {
  constructor() {
    this.dir = app.getPath("userData");
    this.file = path.join(this.dir, "store.json");
    fs.mkdirSync(this.dir, { recursive: true });
    let saved = {};
    try {
      saved = JSON.parse(fs.readFileSync(this.file, "utf8"));
    } catch {}
    this.data = { ...structuredClone(DEFAULTS), ...saved };
  }

  get(key) {
    return this.data[key];
  }

  set(key, value) {
    this.data[key] = value;
    this.save();
    return value;
  }

  save() {
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
  }
}

/** @type {Store} */
export let store;
export function initStore() {
  store = new Store();
  return store;
}
