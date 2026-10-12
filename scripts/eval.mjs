// Mercy eval: tool routing accuracy, latency, multi-turn memory, TTS latency,
// speech-to-text accuracy and latency (Deepgram vs on-device).
//
//   npm run eval
//   npm run eval -- stt     (speech-to-text only)
//
// Calls DeepSeek and Deepgram with the keys in .env. Tools are NOT executed,
// except read-only battery/date commands in the multi-turn check.
import { app } from "electron";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const H = path.join(ROOT, "main");
app.setPath("userData", fs.mkdtempSync(path.join(os.tmpdir(), "mercy-eval-")));
process.loadEnvFile(path.join(ROOT, ".env"));

const ROUTING = [
  ["Open Spotify", "open_app"],
  ["open vscode", "open_app"],
  ["Close Safari", "quit_app"],
  ["Go to youtube", "open_url"],
  ["Search Google for best ramen in Stockholm", "open_url"],
  ["What's on my calendar tomorrow?", "calendar_events"],
  ["Am I free Friday afternoon?", "calendar_events"],
  ["Book dentist next Tuesday at 3pm", "calendar_create"],
  ["Remind me to buy milk at 6", "reminders_add"],
  ["Make a note with my grocery list: eggs, rice, chicken", "notes_create"],
  ["Run my Morning shortcut", "shortcut_run"],
  ["Text Rahma I'll be late", "messages_send|contacts_find"], // looking the contact up first is fine
  ["What's Rahma's number?", "contacts_find"],
  ["How much battery do I have left?", "run_shell"],
  ["What's my IP address?", "run_shell"],
  ["Turn the volume down to 20%", "run_applescript|run_shell"],
  ["Empty my trash", "run_applescript|run_shell"],
  ["Delete everything in my Downloads", "run_shell|run_applescript"],
  ["What's the capital of Japan?", "none"],
  ["Explain what a closure is in JavaScript", "none"],
];

// 4. Speech-to-text: see sttEval().
async function sttEval() {
  // The same spoken phrases through each engine, streamed in
  // real time like the mic, then finalized like releasing push-to-talk.
  // Samples are macOS `say` voices: clean audio, so this compares engines, not
  // how well either copes with a noisy room.
  console.log("\n=== 4. Speech-to-text ===");
  const { DeepgramStream } = await import(`${H}/stt/deepgram.js`);
  const { AppleStream, appleSttSupported, prepareAppleStt } = await import(`${H}/stt/apple.js`);
  const { getKey } = await import(`${H}/keys.js`);
  const PHRASES = [
    "Hey, what does a 429 status code mean?",
    "Remind me to call Amina tomorrow at 9.",
    "Open Safari and search for flights to Nairobi.",
    "What's on my calendar this afternoon?",
    "Send a message to Mum saying I'll be late.",
    "How do I undo the last commit in git but keep my changes?",
  ];
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mercy-stt-"));
  const samples = PHRASES.map((text, i) => {
    const wav = path.join(tmp, `${i}.wav`);
    execFileSync("say", ["-o", wav, "--file-format=WAVE", "--data-format=LEI16@16000", text]);
    const buf = fs.readFileSync(wav);
    for (let off = 12; off < buf.length; ) {
      const id = buf.toString("ascii", off, off + 4), len = buf.readUInt32LE(off + 4);
      if (id === "data") return { text, pcm: buf.subarray(off + 8, off + 8 + len) };
      off += 8 + len + (len & 1);
    }
    throw new Error(`no audio in ${wav}`);
  });
  const words = (t) => t.toLowerCase().replace(/[^a-z0-9' ]/g, " ").split(/\s+/).filter(Boolean);
  function wer(ref, hyp) {
    const r = words(ref), h = words(hyp);
    let prev = Array.from({ length: h.length + 1 }, (_, j) => j);
    for (let i = 1; i <= r.length; i++) {
      const row = [i];
      for (let j = 1; j <= h.length; j++) row[j] = Math.min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (r[i - 1] === h[j - 1] ? 0 : 1));
      prev = row;
    }
    return prev[h.length] / r.length;
  }
  const engines = [];
  if (getKey("deepgram")) engines.push(["deepgram", (opts) => new DeepgramStream({ ...opts, apiKey: getKey("deepgram") })]);
  else console.log("deepgram: skipped (no key)");
  if (appleSttSupported()) {
    try {
      const binary = await prepareAppleStt();
      engines.push(["apple", (opts) => new AppleStream({ ...opts, binary })]);
    } catch (err) {
      console.log(`apple: skipped (${err.message.split("\n")[0]})`);
    }
  } else console.log("apple: skipped (needs macOS 26)");

  async function transcribe(make, { text, pcm }) {
    const heard = [];
    let interim = "", firstResult = 0, ready;
    const live = new Promise((r) => (ready = r));
    const stream = make({
      name: "eval",
      sampleRate: 16000,
      language: "en-US",
      onState: (s) => s === "live" && ready(),
      onResult: (r) => {
        firstResult ||= Date.now();
        if (r.final) (heard.push(r.text), (interim = ""));
        else interim = r.text;
      },
    });
    stream.connect();
    await live;
    const start = Date.now();
    for (let i = 0; i < pcm.length; i += 1024) {
      stream.send(pcm.subarray(i, i + 1024));
      await new Promise((r) => setTimeout(r, 32));
    }
    const released = Date.now();
    await stream.finalize(1500);
    const finalizeMs = Date.now() - released;
    stream.close();
    const hyp = [...heard, interim].join(" ").trim();
    return { hyp, wer: wer(text, hyp), firstMs: firstResult ? firstResult - start : null, finalizeMs };
  }

  for (const [name, make] of engines) {
    const rows = [];
    for (const sample of samples) rows.push(await transcribe(make, sample));
    const avg = (k) => rows.reduce((n, r) => n + (r[k] ?? 0), 0) / rows.length;
    console.log(`\n${name}: WER ${(avg("wer") * 100).toFixed(1)}%  first words ${avg("firstMs").toFixed(0)}ms  release→text ${avg("finalizeMs").toFixed(0)}ms`);
    rows.forEach((r, i) => r.wer > 0 && console.log(`  ✗ ${(r.wer * 100).toFixed(0)}%  "${r.hyp}"  (said: "${PHRASES[i]}")`));
  }
  fs.rmSync(tmp, { recursive: true, force: true });
}

app.whenReady().then(async () => {
  const { initStore } = await import(`${H}/store.js`);
  initStore();
  // npm run eval -- stt: only the speech-to-text comparison.
  if (process.argv.includes("stt")) {
    await sttEval();
    return app.exit(0);
  }
  const { TOOL_DEFS } = await import(`${H}/tools.js`);
  const { streamChat, MODELS } = await import(`${H}/llm/deepseek.js`);
  const { Brain } = await import(`${H}/brain.js`);
  const { TtsStream } = await import(`${H}/tts/stream.js`);

  // System prompt exactly as the app builds it.
  const stubBrain = new Brain({ emit() {}, onFrame() {} }, { context: {}, onChange() {} }, null);
  const system = stubBrain.answerMessages("x", "general")[0];

  // 1. Routing (model only, no tool execution), run in parallel.
  const results = await Promise.all(
    ROUTING.map(async ([ask, expect]) => {
      const t0 = Date.now();
      let first = 0, calls = null, text = "";
      try {
        for await (const ev of streamChat({ model: MODELS.answer, messages: [system, { role: "user", content: ask }], tools: TOOL_DEFS, maxTokens: 300, temperature: 0.5 })) {
          if (!first) first = Date.now() - t0;
          if (ev.type === "tool_calls") calls = ev.calls; else text += ev.delta;
        }
      } catch (e) { text = "ERROR " + e.message; }
      const got = calls ? calls.map((c) => c.name).join("+") : "none";
      const pass = expect.split("|").some((e) => got.split("+")[0] === e);
      return { ask, expect, got, pass, first, args: calls?.[0]?.arguments ?? text.slice(0, 80) };
    }),
  );
  let passed = 0;
  console.log("=== 1. TOOL ROUTING ===");
  for (const r of results) {
    if (r.pass) passed++;
    console.log(`${r.pass ? "PASS" : "FAIL"}  ${String(r.first).padStart(5)}ms  ${r.ask}  → ${r.got}  ${r.args.slice(0, 110)}`);
  }
  const firsts = results.map((r) => r.first).sort((a, b) => a - b);
  console.log(`routing ${passed}/${results.length}, first-event median ${firsts[Math.floor(firsts.length / 2)]}ms, max ${firsts.at(-1)}ms`);

  // 2. Multi-turn memory through the real Brain (read-only commands auto-approved).
  console.log("\n=== 2. MULTI-TURN ===");
  const frames = [];
  const perms = { request: async (req) => (console.log(`  [ask] ${req.detail}`), /^(df|pmset|date|uptime)\b/.test(req.detail) ? "allow" : "deny") };
  const brain = new Brain({ emit: (f) => (frames.push(f), frames.length), onFrame() {} }, { context: {}, onChange() {} }, perms);
  const turn = async (q) => {
    frames.length = 0;
    const t0 = Date.now();
    await brain.ask(q);
    const ans = frames.filter((f) => f.type === "turn.token").map((f) => f.data.delta).join("").trim();
    const tools = frames.filter((f) => f.type === "tool.started").map((f) => f.data.name);
    console.log(`Q: ${q}\n   tools=[${tools}] ${Date.now() - t0}ms\n   A: ${ans.replace(/\s+/g, " ").slice(0, 220)}`);
  };
  await turn("How much battery do I have?");
  await turn("And is it charging?");
  await turn("What did I ask you first?");

  // 3. Streaming TTS: time to first audio chunk on a warm socket.
  console.log("\n=== 3. TTS (streaming) ===");
  let mark = 0;
  let resolveChunk;
  const tts = new TtsStream({
    model: () => "aura-2-andromeda-en",
    onAudio: () => {
      if (mark) {
        resolveChunk(Date.now() - mark);
        mark = 0;
      }
    },
  });
  const t0 = Date.now();
  await tts.warm();
  console.log(`connect ${Date.now() - t0}ms`);
  for (const text of ["Sure.", "You've got two meetings tomorrow, the first one's at nine."]) {
    const first = new Promise((r) => (resolveChunk = r));
    mark = Date.now();
    tts.speak(text);
    console.log(`first audio ${await first}ms  "${text}"`);
    await new Promise((r) => setTimeout(r, 1500));
  }
  tts.close();

  await sttEval();
  app.exit(0);
});
