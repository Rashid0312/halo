// Voice sampler: renders the same line in every matching Deepgram Aura-2 voice
// so you can pick Halo's voice by ear.
//
//   node --env-file=.env scripts/voice-sampler.mjs                 # all English feminine voices
//   node --env-file=.env scripts/voice-sampler.mjs --play          # ...and play them in order
//   node --env-file=.env scripts/voice-sampler.mjs --voices thalia,luna --play
//   node --env-file=.env scripts/voice-sampler.mjs --tag masculine --text "Hi there"
//
// Clips land in ./voice-samples (gitignored), named NN-<voice>.mp3.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const DEFAULT_TEXT =
  "Hey, I'm Halo. You've got two meetings tomorrow, the first one's at nine. Want me to add a reminder the night before?";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : fallback;
};
const text = opt("text", DEFAULT_TEXT);
const tag = opt("tag", "feminine");
const only = opt("voices", "")
  .split(",")
  .map((v) => v.trim().toLowerCase())
  .filter(Boolean);
const play = args.includes("--play");
const outDir = path.resolve(opt("out", "voice-samples"));

const apiKey = process.env.DEEPGRAM_API_KEY;
if (!apiKey) {
  console.error("DEEPGRAM_API_KEY missing — run with: node --env-file=.env scripts/voice-sampler.mjs");
  process.exit(1);
}
const headers = { Authorization: `Token ${apiKey}` };

const res = await fetch("https://api.deepgram.com/v1/models", { headers });
if (!res.ok) throw new Error(`models: ${res.status} ${await res.text()}`);
const { tts = [] } = await res.json();

const seen = new Set();
const voices = tts.filter((m) => {
  const md = m.metadata ?? {};
  if (m.architecture !== "aura-2" || seen.has(m.canonical_name)) return false;
  if (!m.languages?.some((l) => l.startsWith("en"))) return false;
  if (only.length ? !only.includes(m.name.toLowerCase()) : !md.tags?.includes(tag)) return false;
  seen.add(m.canonical_name);
  return true;
});
if (!voices.length) {
  console.error("no voices matched");
  process.exit(1);
}

fs.mkdirSync(outDir, { recursive: true });
const files = [];
for (const [i, m] of voices.entries()) {
  const md = m.metadata ?? {};
  const file = path.join(outDir, `${String(i + 1).padStart(2, "0")}-${m.name}.mp3`);
  const r = await fetch(`https://api.deepgram.com/v1/speak?model=${m.canonical_name}&encoding=mp3`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!r.ok) {
    console.error(`✗ ${m.canonical_name}: ${r.status} ${await r.text()}`);
    continue;
  }
  fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
  const traits = (md.tags ?? []).filter((t) => t !== tag).join(", ");
  console.log(`✓ ${path.basename(file).padEnd(18)} ${(md.accent ?? "").padEnd(10)} ${(md.age ?? "").padEnd(12)} ${traits}`);
  files.push({ file, name: md.display_name ?? m.name });
}
console.log(`\n${files.length} clips in ${outDir}`);

if (play) {
  for (const { file, name } of files) {
    console.log(`▶ ${name}`);
    execFileSync("afplay", [file]);
  }
}
