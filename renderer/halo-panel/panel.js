// Halo panel: drops down from the menu bar icon like Control Center —
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
  idle: "Enter to send · say “Hey Halo”",
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
    if (state === "idle" && !card.matches(":hover") && $("menu").hidden && !enrollEl?.dataset.active && !log.querySelector(".perm:not(.allowed):not(.denied)")) {
      // Tuck back into the menu bar; the conversation stays.
      window.halo.invoke("halo:autoHide").catch(() => {});
    }
  }, COLLAPSE_AFTER_MS);
}
card.addEventListener("mouseleave", () => state === "idle" && scheduleCollapse());

// Keep the native window exactly the size of the card.
new ResizeObserver(() => {
  const r = card.getBoundingClientRect();
  window.halo.invoke("halo:resize", { width: Math.ceil(r.width), height: Math.ceil(r.height) }).catch(() => {});
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
      const el = addMsg("halo", "Halo");
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
  window.halo.invoke("halo:askText", text).catch((err) => addNote(err.message, "error"));
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
    else window.halo.invoke("halo:autoHide");
  }
});
input.addEventListener("focus", expand);

// ── controls ───────────────────────────────────────────────────────────
const talk = () => window.halo.invoke("halo:toggleTalk").catch((err) => addNote(err.message, "error"));
$("orb").addEventListener("click", talk);
$("talk").addEventListener("click", talk);
$("screen").addEventListener("click", () => window.halo.invoke("halo:solveScreen").catch((err) => addNote(err.message, "error")));
$("quit").addEventListener("click", () => window.halo.invoke("halo:quit"));
$("settings").addEventListener("click", () => {
  $("menu").hidden = !$("menu").hidden;
  expand();
});
// Esc tucks the panel back into the menu bar (like Control Center).
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && document.activeElement !== input) window.halo.invoke("halo:autoHide");
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
  el.querySelector(".perm-title").textContent = req.kind === "message" ? req.title : `Halo wants to: ${req.title}`;
  el.querySelector(".perm-why").textContent = req.why || "";
  el.querySelector(".perm-detail").textContent = req.detail;
  el.querySelector(".primary").textContent = req.allowLabel || "Allow once";
  const always = el.querySelector('[data-d="always"]');
  if (always) always.textContent = req.alwaysLabel || "Always allow";
  el.addEventListener("click", (e) => {
    const d = e.target.closest("button")?.dataset.d;
    if (d) window.halo.invoke("halo:permissionReply", { id: req.id, decision: d });
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

// ── audio: Halo's voice streams in as PCM16 chunks and plays gaplessly ──
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
  window.halo.invoke("halo:playback", { playing: on, gen: player.gen }).catch(() => {});
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
      window.halo.invoke("halo:level", level).catch(() => {});
    }
  }
  requestAnimationFrame(meter);
}

// ── "Hey Halo" + voice enrollment ──────────────────────────────────────
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

/** First run (or re-train): invite the user to teach Halo their voice. */
function showEnrollInvite() {
  if (enrollEl || !wake.available) return;
  enrollEl = document.createElement("div");
  enrollEl.className = "enroll";
  enrollEl.innerHTML = `
    <div class="enroll-title">Teach Halo your voice</div>
    <div class="enroll-text">Say “Hey Halo” five times and read three short sentences, so Halo only answers to you. Your voice profile stays on this Mac, encrypted in your Keychain.</div>
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
    <div class="enroll-title">Say “Hey Halo”</div>
    <div class="enroll-dots">${'<span></span>'.repeat(8)}</div>
    <div class="enroll-meter"><i></i></div>
    <div class="enroll-text">Speak normally, then pause.</div>
    <div class="perm-actions"><button class="btn ghost" data-a="cancel">Cancel</button></div>`;
  enrollEl.dataset.active = "1";
  enrollEl.onclick = (e) => {
    if (e.target.closest("button")?.dataset.a === "cancel") {
      window.halo.invoke("halo:enrollCancel");
      closeEnroll();
    }
  };
  expand();
  try {
    await window.halo.invoke("halo:enrollStart");
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
      <div class="enroll-title">Done — Halo knows your voice</div>
      <div class="enroll-text">Say “Hey Halo” anytime. She'll get better at recognizing you the more you talk.</div>`;
    setTimeout(closeEnroll, 6000);
  } else if (!ev.ok) {
    text.textContent = ev.reason ?? "Try again.";
    text.classList.add("warn");
  } else {
    text.classList.remove("warn");
    const phrase = ev.prompt === "Hey Halo";
    enrollEl.querySelector(".enroll-title").textContent = phrase ? "Say “Hey Halo”" : `Read: “${ev.prompt}”`;
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
  if (!wake.available) return addNote('Voice models are missing — run "npm run models" in the halo folder.', "error");
  if (!wake.enrolled) return startEnroll();
  renderWake(await window.halo.invoke("halo:setWake", !wake.enabled));
});
$("tileSpeak").addEventListener("click", () => {
  renderSpeak(!speakOn);
  window.halo.invoke("halo:setVoiceEnabled", speakOn);
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
  renderWake(await window.halo.invoke("halo:voiceDelete"));
  addNote("Your voice profile was deleted from this Mac.");
});

// ── "Connect Halo": the user's own Deepgram + DeepSeek keys ────────────
let connectEl = null;

function showConnect({ change = false } = {}) {
  if (connectEl) return;
  connectEl = document.createElement("div");
  connectEl.className = "enroll connect";
  connectEl.innerHTML = `
    <div class="enroll-title">${change ? "API keys" : "Connect Halo"}</div>
    <div class="enroll-text">Halo uses your own keys: <b>Deepgram</b> for her voice and <b>DeepSeek</b> for her brain. Both give free credit to start. They're stored encrypted on this Mac.</div>
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
    <div class="perm-actions">
      <button class="btn primary" data-a="save">${change ? "Save" : "Connect"}</button>
      ${change ? '<button class="btn ghost" data-a="cancel">Cancel</button>' : ""}
    </div>`;
  connectEl.addEventListener("click", async (e) => {
    const consoleFor = e.target.closest("[data-console]")?.dataset.console;
    if (consoleFor) return window.halo.invoke("halo:openKeyConsole", consoleFor);
    const a = e.target.closest("button")?.dataset.a;
    if (a === "cancel") return closeConnect();
    if (a !== "save") return;
    const btn = e.target.closest("button");
    btn.disabled = true;
    btn.textContent = "Checking…";
    const value = (n) => connectEl.querySelector(`[data-key="${n}"]`).value;
    const res = await window.halo.invoke("halo:setKeys", { deepgram: value("deepgram"), deepseek: value("deepseek") });
    btn.disabled = false;
    btn.textContent = change ? "Save" : "Connect";
    for (const n of ["deepgram", "deepseek"]) {
      const missing = !res.errors[n] && !res[n] ? "Paste this key to continue." : "";
      connectEl.querySelector(`[data-error="${n}"]`).textContent = res.errors[n] || missing;
    }
    if (res.ok && res.ready) {
      closeConnect();
      addNote(change ? "Keys updated." : "Connected — Halo can talk now.");
      if (wake.available && !wake.enrolled) showEnrollInvite();
    }
  });
  log.prepend(connectEl);
  expand();
  requestAnimationFrame(() => connectEl.querySelector("input")?.focus());
}

function closeConnect() {
  connectEl?.remove();
  connectEl = null;
}

$("loginToggle").addEventListener("change", async (e) => {
  e.target.checked = await window.halo.invoke("halo:setOpenAtLogin", e.target.checked);
});
$("showLogs").addEventListener("click", () => {
  $("menu").hidden = true;
  window.halo.invoke("halo:showLogs");
});
window.halo.invoke("halo:getOpenAtLogin").then((on) => ($("loginToggle").checked = on));

$("apiKeys").addEventListener("click", () => {
  $("menu").hidden = true;
  showConnect({ change: true });
});

// ── wire up ────────────────────────────────────────────────────────────
window.halo.on("speech:realtime-frame:received", onFrame);
window.halo.on("halo:state", (s) => setState(s));
window.halo.on("halo:asked", (text) => userFinal(text));
window.halo.on("halo:permission", showPermission);
window.halo.on("halo:audio", playChunk);
window.halo.on("halo:audioStop", ({ gen }) => stopAudio(gen));
window.halo.on("halo:wake", renderWake);
window.halo.on("halo:speak", renderSpeak);

// A newer Halo is on GitHub: offer the download (shown once per launch).
let updateShown = false;
function showUpdate(info) {
  if (!info || updateShown) return;
  updateShown = true;
  const el = document.createElement("div");
  el.className = "enroll";
  el.innerHTML = `<div class="enroll-title"></div>
    <div class="enroll-text">Download the new version and drag it into Applications to replace this one.</div>
    <div class="perm-actions"><button class="btn primary" data-a="get">Download</button><button class="btn ghost" data-a="later">Later</button></div>`;
  el.querySelector(".enroll-title").textContent = `Halo ${info.version} is out`;
  el.addEventListener("click", (e) => {
    const a = e.target.closest("button")?.dataset.a;
    if (a === "get") window.halo.invoke("halo:openUpdate");
    if (a) el.remove();
  });
  log.prepend(el);
}
window.halo.on("halo:update", showUpdate);
window.halo.invoke("halo:updateInfo").then(showUpdate);
// Opened from the menu bar icon: show the conversation, cursor in the text box.
window.halo.on("halo:openComposer", () => {
  // Control Center–style drop-in each time it opens.
  card.classList.remove("open");
  void card.offsetWidth;
  card.classList.add("open");
  $("menu").hidden = true;
  scheduleCollapse();
  requestAnimationFrame(() => input.focus());
});
window.halo.on("halo:startEnroll", () => startEnroll());
window.halo.on("halo:trayHidden", () =>
  addNote("Your menu bar is full, so macOS is hiding Halo's icon. Hold ⌘ and drag a few menu bar icons off, or move Halo's icon right (⌘-drag) when it shows. “Hey Halo” still works."),
);
window.halo.on("halo:enroll", onEnroll);
Promise.all([window.halo.invoke("halo:keysState"), window.halo.invoke("halo:wakeState")]).then(([keys, s]) => {
  renderWake(s);
  // First run: keys first, then voice setup.
  if (!keys.ready) showConnect();
  else if (s.available && !s.enrolled) showEnrollInvite();
});
window.halo.on("halo:permission:closed", closePermission);
window.halo.invoke("halo:getState").then((s) => {
  renderSpeak(s.voiceEnabled);
  setState(s.state);
});
