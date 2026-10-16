// Mercy panel: drops down from the menu bar icon like Control Center —
// quick-control tiles, the conversation, and a text box.
import { animateOrb } from "../shared/pixel-orb.js";

const $ = (id) => document.getElementById(id);
const card = $("card");
const log = $("log");
const label = $("label");
const talkText = $("talkText");

const COLLAPSE_AFTER_MS = 25000;
const LABELS = { idle: "Ready", listening: "Listening…", thinking: "Thinking…", speaking: "Speaking…", waiting: "Needs your OK" };
const TALK = {
  idle: "Enter to send · say “Hey Mercy”",
  listening: "Listening… tap 🎤 to send",
  thinking: "Working on it…",
  speaking: "Type or tap 🎤 to interrupt",
  waiting: "Allow above, or type / say yes or no",
};

let state = "idle";
let live = null; // { el, segments: Map<segId, text> } user bubble being transcribed
let turns = new Map(); // turnId -> { el, raw, raf }
let collapseTimer = 0;

// ── state ──────────────────────────────────────────────────────────────
function setState(next) {
  state = next;
  card.dataset.state = next;
  label.textContent = LABELS[next] ?? "Ready";
  talkText.textContent = TALK[next] ?? TALK.idle;
  if (next !== "idle") expand();
  else scheduleCollapse();
}

/** Something is happening: don't tuck the panel away. */
function expand() {
  clearTimeout(collapseTimer);
}

function scheduleCollapse() {
  clearTimeout(collapseTimer);
  collapseTimer = setTimeout(() => {
    if (state === "idle" && !card.matches(":hover") && $("menu").hidden && !enrollEl?.dataset.active && !permsEl && !log.querySelector(".perm:not(.allowed):not(.denied)")) {
      // Tuck back into the menu bar; the conversation stays.
      window.mercy.invoke("mercy:autoHide").catch(() => {});
    }
  }, COLLAPSE_AFTER_MS);
}
card.addEventListener("mouseleave", () => state === "idle" && scheduleCollapse());

// Keep the native window exactly the size of the card.
new ResizeObserver(() => {
  const r = card.getBoundingClientRect();
  window.mercy.invoke("mercy:resize", { width: Math.ceil(r.width), height: Math.ceil(r.height) }).catch(() => {});
}).observe(card);

// ── messages ───────────────────────────────────────────────────────────
function addMsg(kind, who) {
  const el = document.createElement("div");
  el.className = `msg ${kind}`;
  el.innerHTML = `<span class="who">${who}</span><div class="tools"></div><div class="text"></div>`;
  log.append(el);
  expand();
  scrollDown();
  return el;
}

function addNote(text, cls = "") {
  const el = document.createElement("div");
  el.className = `note ${cls}`;
  el.textContent = text;
  log.append(el);
  expand();
  scrollDown();
}

function scrollDown() {
  requestAnimationFrame(() => (log.scrollTop = log.scrollHeight));
}

function userLive(segId, text) {
  if (!live) {
    const el = addMsg("user live", "You");
    live = { el, segments: new Map() };
  }
  live.segments.set(segId, text);
  live.el.querySelector(".text").textContent = [...live.segments.values()].join(" ");
  scrollDown();
}

function userFinal(text) {
  const el = live?.el ?? addMsg("user", "You");
  el.classList.remove("live");
  el.querySelector(".text").textContent = text;
  live = null;
}

function onFrame(raw) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch {
    return;
  }
  const d = frame.data ?? {};
  switch (frame.type) {
    case "transcript":
      if (d.role === "user" && state === "listening" && d.text) userLive(d.segment_id, d.text);
      break;
    case "turn.started": {
      const el = addMsg("mercy", "Mercy");
      turns.set(d.turn_id, { el, raw: "", raf: 0 });
      break;
    }
    case "turn.token": {
      const t = turns.get(d.turn_id);
      if (!t) break;
      t.raw += d.delta;
      if (!t.raf) t.raf = requestAnimationFrame(() => paint(t));
      break;
    }
    case "turn.done": {
      const t = turns.get(d.turn_id);
      if (t) paint(t);
      turns.delete(d.turn_id);
      break;
    }
    case "turn.superseded":
      turns.delete(d.turn_id);
      break;
    case "tool.started": {
      const t = turns.get(d.turn_id);
      if (!t) break;
      const chip = document.createElement("div");
      chip.className = "chip running";
      chip.dataset.call = d.call_id;
      chip.textContent = d.label || d.name;
      t.el.querySelector(".tools").append(chip);
      scrollDown();
      break;
    }
    case "tool.done": {
      const chip = log.querySelector(`.chip[data-call="${CSS.escape(d.call_id)}"]`);
      if (chip) chip.className = `chip ${d.ok ? "ok" : "failed"}`;
      break;
    }
    case "screen.analysed":
      addNote(d.title || "Looking at your screen…");
      break;
    case "error":
      addNote(d.message || "Something went wrong", "error");
      break;
  }
}

function paint(t) {
  t.raf = 0;
  t.el.querySelector(".text").innerHTML = markdown(t.raw);
  scrollDown();
}

// ── tiny markdown: fences, inline code, bold, lists, paragraphs ────────
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const inline = (s) =>
  esc(s)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");

function markdown(src) {
  const out = [];
  const parts = src.split(/^```[^\n]*\n?/m);
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      out.push(`<div class="code"><button class="copy">Copy</button><pre><code>${esc(part.replace(/\n$/, ""))}</code></pre></div>`);
      return;
    }
    let list = null;
    for (const line of part.split("\n")) {
      const item = line.match(/^\s*(?:[-*•]|(\d+)[.)])\s+(.*)/);
      if (item) {
        const tag = item[1] ? "ol" : "ul";
        if (list !== tag) {
          if (list) out.push(`</${list}>`);
          out.push(`<${tag}>`);
          list = tag;
        }
        out.push(`<li>${inline(item[2])}</li>`);
        continue;
      }
      if (list) {
        out.push(`</${list}>`);
        list = null;
      }
      const h = line.replace(/^#{1,6}\s+/, "");
      if (h.trim()) out.push(`<p>${line !== h ? `<strong>${inline(h)}</strong>` : inline(h)}</p>`);
    }
    if (list) out.push(`</${list}>`);
  });
  return out.join("");
}

log.addEventListener("click", (e) => {
  const btn = e.target.closest(".copy");
  if (!btn) return;
  navigator.clipboard.writeText(btn.nextElementSibling.textContent);
  btn.textContent = "Copied";
  setTimeout(() => (btn.textContent = "Copy"), 1200);
});

// ── typing ─────────────────────────────────────────────────────────────
const input = $("input");
function sendText() {
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  fitInput();
  window.mercy.invoke("mercy:askText", text).catch((err) => addNote(err.message, "error"));
}
function fitInput() {
  input.style.height = "auto";
  input.style.height = `${Math.min(input.scrollHeight, 120)}px`;
}
$("ask").addEventListener("submit", (e) => {
  e.preventDefault();
  sendText();
});
input.addEventListener("input", fitInput);
input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
    e.preventDefault();
    sendText();
  } else if (e.key === "Escape") {
    if (input.value) input.blur();
    else window.mercy.invoke("mercy:autoHide");
  }
});
input.addEventListener("focus", expand);

// ── controls ───────────────────────────────────────────────────────────
const talk = () => window.mercy.invoke("mercy:toggleTalk").catch((err) => addNote(err.message, "error"));
$("orb").addEventListener("click", talk);
$("talk").addEventListener("click", talk);
$("screen").addEventListener("click", () => window.mercy.invoke("mercy:solveScreen").catch((err) => addNote(err.message, "error")));
$("quit").addEventListener("click", () => window.mercy.invoke("mercy:quit"));
$("settings").addEventListener("click", () => {
  $("menu").hidden = !$("menu").hidden;
  if (!$("menu").hidden) (loadEngine(), loadBrain(), window.mercy.invoke("mercy:samplesState").then(renderSamples)); // may have changed from the menu bar
  expand();
});
// Esc tucks the panel back into the menu bar (like Control Center).
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && document.activeElement !== input) window.mercy.invoke("mercy:autoHide");
});

// ── permission requests ────────────────────────────────────────────────
function showPermission(req) {
  const el = document.createElement("div");
  el.className = "perm";
  el.dataset.id = req.id;
  el.innerHTML = `
    <div class="perm-title"></div>
    <div class="perm-why"></div>
    <pre class="perm-detail"></pre>
    <div class="perm-actions">
      <button class="btn primary" data-d="allow"></button>
      ${req.alwaysKey ? '<button class="btn" data-d="always"></button>' : ""}
      <button class="btn ghost" data-d="deny">Deny</button>
    </div>`;
  el.querySelector(".perm-title").textContent = req.kind === "message" || req.kind === "claude" ? req.title : `Mercy wants to: ${req.title}`;
  el.querySelector(".perm-why").textContent = req.why || "";
  el.querySelector(".perm-detail").textContent = req.detail;
  el.querySelector(".primary").textContent = req.allowLabel || "Allow once";
  const always = el.querySelector('[data-d="always"]');
  if (always) always.textContent = req.alwaysLabel || "Always allow";
  el.addEventListener("click", (e) => {
    const d = e.target.closest("button")?.dataset.d;
    if (d) window.mercy.invoke("mercy:permissionReply", { id: req.id, decision: d });
  });
  log.append(el);
  expand();
  scrollDown();
  el.querySelector(".primary").focus();
}

function closePermission({ id, decision, reason }) {
  const el = log.querySelector(`.perm[data-id="${CSS.escape(id)}"]`);
  if (!el) return;
  el.classList.add(decision === "deny" ? "denied" : "allowed");
  el.querySelector(".perm-actions").outerHTML = `<div class="perm-result">${
    decision === "deny" ? `Denied${reason && reason !== "voice" ? ` (${reason})` : ""}` : "Allowed"
  }</div>`;
}

// ── audio: Mercy's voice streams in as PCM16 chunks and plays gaplessly ──
const player = { ctx: null, out: null, level: null, next: 0, gen: 0, sources: new Set(), playing: false };

function audioCtx(rate) {
  if (!player.ctx) {
    player.ctx = new AudioContext({ sampleRate: rate });
    player.level = player.ctx.createAnalyser();
    player.level.fftSize = 512;
    player.out = player.ctx.createGain();
    player.out.connect(player.level).connect(player.ctx.destination);
    requestAnimationFrame(meter);
  }
  if (player.ctx.state === "suspended") player.ctx.resume();
  return player.ctx;
}

function setPlaying(on) {
  if (player.playing === on) return;
  player.playing = on;
  window.mercy.invoke("mercy:playback", { playing: on, gen: player.gen }).catch(() => {});
}

function playChunk({ gen, rate, pcm }) {
  if (gen < player.gen) return;
  if (gen > player.gen) stopAudio(gen);
  const ctx = audioCtx(rate);
  const bytes = pcm instanceof Uint8Array ? pcm : new Uint8Array(pcm);
  const n = bytes.byteLength >> 1;
  if (!n) return;
  const view = new DataView(bytes.buffer, bytes.byteOffset, n * 2);
  const buf = ctx.createBuffer(1, n, rate);
  const ch = buf.getChannelData(0);
  for (let i = 0; i < n; i++) ch[i] = view.getInt16(i * 2, true) / 32768;
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(player.out);
  const at = Math.max(ctx.currentTime + 0.03, player.next);
  src.start(at);
  player.next = at + buf.duration;
  player.sources.add(src);
  setPlaying(true);
  src.onended = () => {
    player.sources.delete(src);
    if (!player.sources.size && gen === player.gen) setPlaying(false);
  };
}

function stopAudio(gen) {
  player.gen = gen;
  for (const src of player.sources) {
    src.onended = null;
    try {
      src.stop();
    } catch {}
  }
  player.sources.clear();
  player.next = 0;
  player.playing = false;
  card.style.setProperty("--level", "0");
}

// Voice loudness → the orb (and the Touch Bar orb) pulse with her voice.
let voiceLevel = 0;
animateOrb($("orb").querySelector("canvas"), () => ({
  state: state === "idle" && card.dataset.followup === "true" ? "followup" : state,
  level: voiceLevel,
}));
const levelData = new Uint8Array(512);
function meter() {
  if (player.level) {
    player.level.getByteTimeDomainData(levelData);
    let sum = 0;
    for (const v of levelData) sum += (v - 128) ** 2;
    const rms = Math.sqrt(sum / levelData.length) / 128;
    const level = player.playing ? Math.min(1, rms * 4) : 0;
    voiceLevel = level;
    card.style.setProperty("--level", level.toFixed(3));
    // ~20×/s to the Touch Bar face's mouth (and one 0 when she stops).
    const now = performance.now();
    if ((level > 0 || player.lastLevel > 0) && now - (player.levelSentAt ?? 0) > 50) {
      player.levelSentAt = now;
      player.lastLevel = level;
      window.mercy.invoke("mercy:level", level).catch(() => {});
    }
  }
  requestAnimationFrame(meter);
}

// ── "Hey Mercy" + voice enrollment ──────────────────────────────────────
let wake = { available: false, enrolled: false, enabled: false, mode: "off" };
let enrollEl = null;

function renderWake(s) {
  wake = s;
  const on = s.enabled && s.enrolled;
  $("tileWake").dataset.on = String(on);
  $("wakeSub").textContent = !s.available ? "Unavailable" : !s.enrolled ? "Set up" : on ? "On" : "Off";
  $("tileVoice").dataset.on = String(s.enrolled);
  $("voiceSub").textContent = s.enrolled ? "Trained" : "Not set up";
  $("retrain").hidden = !s.available || !s.enrolled;
  $("forget").hidden = !s.enrolled;
  card.dataset.followup = s.mode === "followup" ? "true" : "false";
  if (s.mode === "followup" && state === "idle") talkText.textContent = "Still listening… just keep talking";
  else talkText.textContent = TALK[state] ?? TALK.idle;
}

/** First run (or re-train): invite the user to teach Mercy their voice. */
function showEnrollInvite() {
  if (enrollEl || !wake.available) return;
  enrollEl = document.createElement("div");
  enrollEl.className = "enroll";
  enrollEl.innerHTML = `
    <div class="enroll-title">Teach Mercy your voice</div>
    <div class="enroll-text">Say “Hey Mercy” five times and read three short sentences, so Mercy only answers to you. Your voice profile stays on this Mac, encrypted in your Keychain.</div>
    <div class="perm-actions">
      <button class="btn primary" data-a="start">Set up</button>
      <button class="btn ghost" data-a="later">Not now</button>
    </div>`;
  enrollEl.addEventListener("click", (e) => {
    const a = e.target.closest("button")?.dataset.a;
    if (a === "start") startEnroll();
    else if (a === "later") closeEnroll();
  });
  log.append(enrollEl);
  expand();
  scrollDown();
}

async function startEnroll() {
  if (enrollEl?.dataset.active) return; // already recording
  if (!enrollEl) showEnrollInvite();
  enrollEl.innerHTML = `
    <div class="enroll-title">Say “Hey Mercy”</div>
    <div class="enroll-dots">${'<span></span>'.repeat(8)}</div>
    <div class="enroll-meter"><i></i></div>
    <div class="enroll-text">Speak normally, then pause.</div>
    <div class="perm-actions"><button class="btn ghost" data-a="cancel">Cancel</button></div>`;
  enrollEl.dataset.active = "1";
  enrollEl.onclick = (e) => {
    if (e.target.closest("button")?.dataset.a === "cancel") {
      window.mercy.invoke("mercy:enrollCancel");
      closeEnroll();
    }
  };
  expand();
  try {
    await window.mercy.invoke("mercy:enrollStart");
  } catch (err) {
    enrollEl.querySelector(".enroll-text").textContent = err.message;
  }
}

function onEnroll(ev) {
  if (!enrollEl) return;
  if (ev.level !== undefined) {
    const bar = enrollEl.querySelector(".enroll-meter i");
    if (bar) bar.style.width = `${Math.round(ev.level * 100)}%`;
    return;
  }
  const dots = enrollEl.querySelectorAll(".enroll-dots span");
  dots.forEach((d, i) => d.classList.toggle("on", i < (ev.count ?? 0)));
  const text = enrollEl.querySelector(".enroll-text");
  if (ev.done) {
    enrollEl.innerHTML = `
      <div class="enroll-title">Done — Mercy knows your voice</div>
      <div class="enroll-text">Say “Hey Mercy” anytime. She'll get better at recognizing you the more you talk.</div>`;
    setTimeout(closeEnroll, 6000);
  } else if (!ev.ok) {
    text.textContent = ev.reason ?? "Try again.";
    text.classList.add("warn");
  } else {
    text.classList.remove("warn");
    const phrase = ev.prompt === "Hey Mercy";
    enrollEl.querySelector(".enroll-title").textContent = phrase ? "Say “Hey Mercy”" : `Read: “${ev.prompt}”`;
    text.textContent = phrase ? `Got it — again (${ev.count + 1} of ${ev.needed}).` : `Nice. Now read it naturally (${ev.count + 1} of ${ev.needed}).`;
  }
}

function closeEnroll() {
  enrollEl?.remove();
  enrollEl = null;
}

// ── tiles ──────────────────────────────────────────────────────────────
let speakOn = true;
function renderSpeak(on) {
  speakOn = on;
  $("tileSpeak").dataset.on = String(on);
  $("speakSub").textContent = on ? "On" : "Off";
}
$("tileWake").addEventListener("click", async () => {
  if (!wake.available) return addNote('Voice models are missing — run "npm run models" in the mercy folder.', "error");
  if (!wake.enrolled) return startEnroll();
  renderWake(await window.mercy.invoke("mercy:setWake", !wake.enabled));
});
$("tileSpeak").addEventListener("click", () => {
  renderSpeak(!speakOn);
  window.mercy.invoke("mercy:setVoiceEnabled", speakOn);
});
$("tileVoice").addEventListener("click", () => {
  if (wake.available) startEnroll();
});
$("retrain").addEventListener("click", () => {
  $("menu").hidden = true;
  startEnroll();
});
$("forget").addEventListener("click", async () => {
  $("menu").hidden = true;
  renderWake(await window.mercy.invoke("mercy:voiceDelete"));
  addNote("Your voice profile was deleted from this Mac.");
});

// ── "Connect Mercy": Deepgram key (voice) + DeepSeek key or ChatGPT plan (brain) ──
let connectEl = null;

function showConnect({ change = false } = {}) {
  if (connectEl) return;
  connectEl = document.createElement("div");
  connectEl.className = "enroll connect";
  connectEl.innerHTML = `
    <div class="enroll-title">${change ? "API keys" : "Connect Mercy"}</div>
    <div class="enroll-text">Mercy uses your own accounts: <b>Deepgram</b> for her voice, and <b>DeepSeek</b> or your <b>ChatGPT</b> plan for her brain. Keys are stored encrypted on this Mac.</div>
    ${["deepgram", "deepseek"]
      .map(
        (name) => `
      <label class="field">
        <span>${name === "deepgram" ? "Deepgram key" : "DeepSeek key"}
          <button type="button" class="link" data-console="${name}">Get a key</button></span>
        <input type="password" data-key="${name}" placeholder="${change ? "•••••• saved — paste to replace" : "Paste your key"}" autocomplete="off" spellcheck="false" />
        <small class="field-error" data-error="${name}"></small>
      </label>`,
      )
      .join("")}
    <div class="or">or use your ChatGPT plan for her brain</div>
    <div class="chatgpt-row" data-chatgpt></div>
    <div class="perm-actions">
      <button class="btn primary" data-a="save">${change ? "Save" : "Connect"}</button>
      ${change ? '<button class="btn ghost" data-a="cancel">Cancel</button>' : ""}
    </div>`;
  connectEl.addEventListener("click", async (e) => {
    const consoleFor = e.target.closest("[data-console]")?.dataset.console;
    if (consoleFor) return window.mercy.invoke("mercy:openKeyConsole", consoleFor);
    const a = e.target.closest("button")?.dataset.a;
    if (a === "cancel") return closeConnect();
    if (a === "chatgpt" || a === "signout" || a === "usage") return chatgptAction(a, e.target.closest("button"));
    if (a !== "save") return;
    const btn = e.target.closest("button");
    btn.disabled = true;
    btn.textContent = "Checking…";
    const value = (n) => connectEl.querySelector(`[data-key="${n}"]`).value;
    const res = await window.mercy.invoke("mercy:setKeys", { deepgram: value("deepgram"), deepseek: value("deepseek") });
    btn.disabled = false;
    btn.textContent = change ? "Save" : "Connect";
    for (const n of ["deepgram", "deepseek"]) {
      // A ChatGPT plan Mercy can use stands in for the DeepSeek key.
      const missing = !res.errors[n] && !res[n] && !(n === "deepseek" && res.chatgpt) ? "Paste this key to continue." : "";
      connectEl.querySelector(`[data-error="${n}"]`).textContent = res.errors[n] || missing;
    }
    if (res.ok && res.ready) {
      closeConnect();
      addNote(change ? "Keys updated." : "Connected — Mercy can talk now.");
      if (wake.available && !wake.enrolled) showEnrollInvite();
    }
  });
  log.prepend(connectEl);
  window.mercy.invoke("mercy:chatgptState").then(renderChatgpt);
  expand();
  requestAnimationFrame(() => connectEl.querySelector("input")?.focus());
}

/** The ChatGPT row in the Connect card: "Continue with ChatGPT", or who's signed in. */
function renderChatgpt(s) {
  const row = connectEl?.querySelector("[data-chatgpt]");
  if (!row) return;
  row.replaceChildren();
  if (!s.signedIn) {
    row.innerHTML = `
      <button type="button" class="btn chatgpt" data-a="chatgpt"><img src="chatgpt-logo-white.svg" alt="" /> Continue with ChatGPT</button>
      <small>Needs ChatGPT Plus or Pro. Mercy's use counts toward your plan's limits.</small>`;
    return;
  }
  const who = document.createElement("span");
  who.textContent = s.sharing ? `Using your ChatGPT plan · ${s.email}` : `Signed in as ${s.email}, but this ChatGPT plan can't be used by Mercy (it needs Plus or Pro).`;
  const links = document.createElement("span");
  links.innerHTML = `${s.sharing ? '<button type="button" class="link" data-a="usage">Manage usage</button> · ' : ""}<button type="button" class="link" data-a="signout">Sign out</button>`;
  row.append(who, links);
}

async function chatgptAction(a, btn) {
  if (a === "usage") return window.mercy.invoke("mercy:chatgptManageUsage");
  if (a === "signout") return renderChatgpt(await window.mercy.invoke("mercy:chatgptSignOut"));
  btn.disabled = true;
  btn.lastChild.textContent = " Waiting for the browser…";
  try {
    const s = await window.mercy.invoke("mercy:chatgptSignIn");
    renderChatgpt(s);
    if (s.sharing) {
      await window.mercy.invoke("mercy:setBrain", { provider: "chatgpt" });
      loadBrain();
      addNote("You're using your ChatGPT plan for Mercy's brain. Switch back any time under ··· → Brain.");
      const keys = await window.mercy.invoke("mercy:keysState");
      if (keys.ready && !connectEl?.querySelector('[data-key="deepgram"]').value) {
        closeConnect();
        if (wake.available && !wake.enrolled) showEnrollInvite();
      }
    }
  } catch (err) {
    addNote(err.message, "error");
    renderChatgpt(await window.mercy.invoke("mercy:chatgptState"));
  }
}

function closeConnect() {
  connectEl?.remove();
  connectEl = null;
}

$("loginToggle").addEventListener("change", async (e) => {
  e.target.checked = await window.mercy.invoke("mercy:setOpenAtLogin", e.target.checked);
});
// Opt-in test recordings of real requests (main/stt/samples.js): start, or stop + delete.
function renderSamples({ left, saved }) {
  $("recordSamples").textContent = left
    ? `Recording requests: ${left} left · stop & delete`
    : saved
      ? `Delete ${saved} recorded request${saved === 1 ? "" : "s"}`
      : "Record my next 20 requests (testing)";
  $("recordSamples").classList.toggle("danger", Boolean(left || saved));
}
$("recordSamples").addEventListener("click", async () => {
  const st = await window.mercy.invoke("mercy:samplesState");
  renderSamples(await window.mercy.invoke(st.left || st.saved ? "mercy:deleteSamples" : "mercy:setRecording", true));
});
window.mercy.invoke("mercy:samplesState").then(renderSamples);

$("showLogs").addEventListener("click", () => {
  $("menu").hidden = true;
  window.mercy.invoke("mercy:showLogs");
});
window.mercy.invoke("mercy:getOpenAtLogin").then((on) => ($("loginToggle").checked = on));

// Brain: DeepSeek (key) or ChatGPT (your plan); with ChatGPT, which model.
function loadBrain() {
  window.mercy.invoke("mercy:getBrain").then((b) => {
    $("brain").value = b.provider;
    const pick = $("brainModel");
    pick.replaceChildren(...b.models.map((m) => new Option(m.name, m.slug, false, m.slug === b.chatgptModel)));
    pick.closest("label").hidden = b.provider !== "chatgpt" || !b.models.length;
  });
}
loadBrain();
$("brain").addEventListener("change", async (e) => {
  $("menu").hidden = true;
  if (e.target.value === "chatgpt" && !(await window.mercy.invoke("mercy:chatgptState")).sharing) {
    // Not signed in (or the plan can't be used): sign in from the Connect card.
    e.target.value = "deepseek";
    return showConnect({ change: true });
  }
  await window.mercy.invoke("mercy:setBrain", { provider: e.target.value }).catch((err) => addNote(err.message, "error"));
  loadBrain();
});
$("brainModel").addEventListener("change", (e) => {
  $("menu").hidden = true;
  window.mercy.invoke("mercy:setBrain", { model: e.target.value }).catch((err) => addNote(err.message, "error"));
});

// Speech recognition: Deepgram (cloud), on this Mac (Apple, macOS 26+), or auto.
function loadEngine() {
  window.mercy.invoke("speech:getEngine").then(({ engine, onDevice }) => {
    $("sttEngine").value = engine;
    $("sttEngine").querySelector("[value=apple]").disabled = !onDevice;
  });
}
loadEngine();
$("sttEngine").addEventListener("change", (e) => {
  $("menu").hidden = true;
  window.mercy.invoke("speech:setEngine", e.target.value).catch((err) => addNote(err.message, "error"));
});

$("apiKeys").addEventListener("click", () => {
  $("menu").hidden = true;
  showConnect({ change: true });
});

// ── Permissions: how much Mercy is trusted, per kind of action ───────────
const TRUST_ROWS = [
  { kind: "shell", name: "Run commands", hint: "Terminal commands: files, folders, git, installs…", auto: "Deleting, killing or system changes still ask." },
  { kind: "applescript", name: "Control apps", hint: "Click menus, move windows, use Finder, Mail, Music…", auto: "Scripts that run risky commands still ask." },
  { kind: "message", name: "Send messages", hint: "iMessage / SMS from your Messages app.", auto: "Sends without showing you the text first." },
  { kind: "claude", name: "Claude Code asks", hint: "When Claude Code wants permission for a command or edit.", auto: "Mercy allows safe ones; deleting, pushing or system changes still ask.", off: "Claude asks in its own terminal." },
];
const LEVEL_LABEL = { ask: "Ask", auto: "Just do it", off: "Never" };
let permsEl = null;

function alwaysLabel(key) {
  const [kind, rest] = [key.slice(0, key.indexOf(":")), key.slice(key.indexOf(":") + 1)];
  if (kind === "claude") {
    const [what, ...more] = rest.split(":");
    const target = more.join(":");
    return { bash: `Claude runs ${target}`, edit: `Claude edits ${target.split("/").pop()}`, tool: `Claude uses ${target}` }[what] ?? key;
  }
  return { shell: `Command: ${rest}`, applescript: `Control ${rest}`, messages: `Messages to ${rest}` }[kind] ?? key;
}

function renderPerms(settings) {
  for (const row of TRUST_ROWS) {
    const level = settings.trust[row.kind];
    for (const b of permsEl.querySelectorAll(`[data-kind="${row.kind}"] [data-level]`)) {
      b.setAttribute("aria-pressed", String(b.dataset.level === level));
    }
    permsEl.querySelector(`[data-kind="${row.kind}"] .trust-note`).textContent =
      level === "auto" ? row.auto : level === "off" ? row.off ?? "Mercy won't do this." : "Mercy asks you every time.";
  }
  const list = permsEl.querySelector(".always-list");
  list.replaceChildren(
    ...settings.always.map((key) => {
      const chip = document.createElement("span");
      chip.className = "always-chip";
      chip.textContent = alwaysLabel(key);
      const x = document.createElement("button");
      x.textContent = "✕";
      x.title = "Ask again";
      x.dataset.forget = key;
      chip.append(x);
      return chip;
    }),
  );
  permsEl.querySelector(".always").hidden = !settings.always.length;
}

async function showPerms() {
  if (permsEl) return;
  permsEl = document.createElement("div");
  permsEl.className = "enroll perms";
  permsEl.innerHTML = `
    <div class="enroll-title">Permissions</div>
    <div class="enroll-text">How much should Mercy do without asking? Opening apps, websites, Calendar, Reminders and Notes never asks.</div>
    ${TRUST_ROWS.map(
      (r) => `
      <div class="trust" data-kind="${r.kind}">
        <div class="trust-head"><b>${r.name}</b><small>${r.hint}</small></div>
        <div class="seg" role="group" aria-label="${r.name}">
          ${["ask", "auto", "off"].map((l) => `<button type="button" data-level="${l}">${LEVEL_LABEL[l]}</button>`).join("")}
        </div>
        <small class="trust-note"></small>
      </div>`,
    ).join("")}
    <div class="always" hidden>
      <div class="trust-head"><b>Always allowed</b><small>Things you said “Always allow” to. ✕ to be asked again.</small></div>
      <div class="always-list"></div>
    </div>
    <div class="perm-actions"><button class="btn primary" data-a="done">Done</button></div>`;
  permsEl.addEventListener("click", async (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    if (b.dataset.a === "done") return closePerms();
    if (b.dataset.forget) return renderPerms(await window.mercy.invoke("mercy:forgetAlways", b.dataset.forget));
    const kind = b.closest("[data-kind]")?.dataset.kind;
    if (kind && b.dataset.level) renderPerms(await window.mercy.invoke("mercy:setTrust", { kind, level: b.dataset.level }));
  });
  renderPerms(await window.mercy.invoke("mercy:getTrust"));
  log.prepend(permsEl);
  expand();
}

function closePerms() {
  permsEl?.remove();
  permsEl = null;
}

$("permsBtn").addEventListener("click", () => {
  $("menu").hidden = true;
  showPerms();
});

// ── Claude Code: connect, announcements, open sessions ─────────────────
let claudeEl = null;
const STATUS_LABEL = { working: "working", waiting: "waiting for you", idle: "idle" };

function renderClaude(st) {
  if (!claudeEl) return;
  claudeEl.querySelector('[data-c="connected"]').checked = st.connected;
  claudeEl.querySelector('[data-c="announce"]').checked = st.announce;
  const list = claudeEl.querySelector(".claude-list");
  list.replaceChildren(
    ...st.sessions.map((s) => {
      const row = document.createElement("div");
      row.className = "claude-row";
      const b = document.createElement("b");
      b.textContent = s.name;
      const small = document.createElement("small");
      small.textContent = [STATUS_LABEL[s.status] ?? s.status, s.activity, s.goal && `driving: ${s.goal}`].filter(Boolean).join(" · ");
      row.append(b, small);
      return row;
    }),
  );
  claudeEl.querySelector(".claude-empty").hidden = Boolean(st.sessions.length) || !st.connected;
}

async function showClaude() {
  if (claudeEl) return;
  claudeEl = document.createElement("div");
  claudeEl.className = "enroll perms";
  claudeEl.innerHTML = `
    <div class="enroll-title">Claude Code</div>
    <div class="enroll-text">Mercy follows your Claude Code sessions: she tells you when one finishes, passes on what you say, asks you about its permission requests and can keep one going toward a goal. Try “Hey Mercy, what's Claude doing?”</div>
    <label class="row"><input type="checkbox" data-c="connected" /> Connected (hooks in ~/.claude/settings.json)</label>
    <label class="row"><input type="checkbox" data-c="announce" /> Tell me when a session finishes</label>
    <div class="claude-list"></div>
    <small class="trust-note claude-empty">No sessions yet. Claude windows opened before connecting show up after a restart.</small>
    <div class="perm-actions"><button class="btn primary" data-a="done">Done</button></div>`;
  claudeEl.addEventListener("change", async (e) => {
    const c = e.target.dataset.c;
    if (c) renderClaude(await window.mercy.invoke("mercy:setClaude", { [c]: e.target.checked }));
  });
  claudeEl.addEventListener("click", (e) => {
    if (e.target.closest("button")?.dataset.a === "done") {
      claudeEl.remove();
      claudeEl = null;
    }
  });
  log.prepend(claudeEl);
  renderClaude(await window.mercy.invoke("mercy:claudeState"));
  expand();
}

$("claudeBtn").addEventListener("click", () => {
  $("menu").hidden = true;
  showClaude();
});

// ── wire up ────────────────────────────────────────────────────────────
window.mercy.on("speech:realtime-frame:received", onFrame);
window.mercy.on("mercy:state", (s) => setState(s));
window.mercy.on("mercy:asked", (text) => userFinal(text));
window.mercy.on("mercy:permission", showPermission);
window.mercy.on("mercy:openConnect", () => showConnect({ change: true }));
window.mercy.on("mercy:audio", playChunk);
window.mercy.on("mercy:audioStop", ({ gen }) => stopAudio(gen));
window.mercy.on("mercy:wake", renderWake);
window.mercy.on("mercy:speak", renderSpeak);
window.mercy.on("mercy:claude", renderClaude);

// A newer Mercy is on GitHub: offer the download (shown once per launch).
let updateShown = false;
function showUpdate(info) {
  if (!info || updateShown) return;
  updateShown = true;
  const el = document.createElement("div");
  el.className = "enroll";
  el.innerHTML = `<div class="enroll-title"></div>
    <div class="enroll-text">Download the new version and drag it into Applications to replace this one.</div>
    <div class="perm-actions"><button class="btn primary" data-a="get">Download</button><button class="btn ghost" data-a="later">Later</button></div>`;
  el.querySelector(".enroll-title").textContent = `Mercy ${info.version} is out`;
  el.addEventListener("click", (e) => {
    const a = e.target.closest("button")?.dataset.a;
    if (a === "get") window.mercy.invoke("mercy:openUpdate");
    if (a) el.remove();
  });
  log.prepend(el);
}
window.mercy.on("mercy:update", showUpdate);
window.mercy.invoke("mercy:updateInfo").then(showUpdate);
// Opened from the menu bar icon: show the conversation, cursor in the text box.
window.mercy.on("mercy:openComposer", () => {
  // Control Center–style drop-in each time it opens.
  card.classList.remove("open");
  void card.offsetWidth;
  card.classList.add("open");
  $("menu").hidden = true;
  scheduleCollapse();
  requestAnimationFrame(() => input.focus());
});
window.mercy.on("mercy:startEnroll", () => startEnroll());
window.mercy.on("mercy:trayHidden", () =>
  addNote("Your menu bar is full, so macOS is hiding Mercy's icon. Hold ⌘ and drag a few menu bar icons off, or move Mercy's icon right (⌘-drag) when it shows. “Hey Mercy” still works."),
);
window.mercy.on("mercy:enroll", onEnroll);
Promise.all([window.mercy.invoke("mercy:keysState"), window.mercy.invoke("mercy:wakeState")]).then(([keys, s]) => {
  renderWake(s);
  // First run: keys first, then voice setup.
  if (!keys.ready) showConnect();
  else if (s.available && !s.enrolled) showEnrollInvite();
});
window.mercy.on("mercy:permission:closed", closePermission);
window.mercy.invoke("mercy:getState").then((s) => {
  renderSpeak(s.voiceEnabled);
  setState(s.state);
});
