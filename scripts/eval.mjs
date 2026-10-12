// Mercy eval: tool routing accuracy, latency, multi-turn memory, TTS latency.
//
//   npm run eval
//
// Calls DeepSeek and Deepgram with the keys in .env. Tools are NOT executed,
// except read-only battery/date commands in the multi-turn check.
import { app } from "electron";
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

app.whenReady().then(async () => {
  const { initStore } = await import(`${H}/store.js`);
  initStore();
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
  app.exit(0);
});
