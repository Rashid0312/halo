// Words Mercy listens for: names a general speech model gets wrong
// ("official studios" for Visual Studio). Kept short and specific on purpose:
// common words as hints ("Notes", "Home", "Music") pull ordinary speech toward
// them. Used by Deepgram (keyterms) and Apple's dictation model; Apple's
// general model ignores hints (measured: scripts/eval.mjs).
import { store } from "../store.js";
import { claude } from "../claude/index.js";

const CORE = [
  "Mercy",
  "Claude",
  "Claude Code",
  "DeepSeek",
  "ChatGPT",
  "Deepgram",
  "VS Code",
  "Visual Studio Code",
  "Xcode",
  "iTerm",
  "GitHub",
  "npm",
  "git commit",
  "pull request",
];
const MAX = 40;

/** Core terms, then the user's own words, then Claude Code project names. */
export function speechWords() {
  const mine = (store.get("stt")?.words ?? []).map(String);
  const projects = claude.sessions.list().map((s) => s.project);
  const seen = new Set();
  return [...CORE, ...mine, ...projects]
    .map((w) => w.trim())
    .filter((w) => w && !seen.has(w.toLowerCase()) && seen.add(w.toLowerCase()))
    .slice(0, MAX);
}
