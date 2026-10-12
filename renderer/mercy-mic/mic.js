// Mercy's microphone: a hidden window records with Chromium's echo
// cancellation / noise suppression and streams 16 kHz PCM16 chunks to main.
let ctx = null;
let stream = null;
let node = null;

async function start() {
  // A recording whose mic went away (AirPods switched, sleep…) is dead: tear it
  // down and open the current mic instead of reusing it.
  if (ctx && stream?.getAudioTracks()[0]?.readyState === "live") return label();
  if (ctx) await stop();
  stream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
  });
  ctx = new AudioContext({ sampleRate: 16000 });
  await ctx.audioWorklet.addModule("mic-worklet.js");
  node = new AudioWorkletNode(ctx, "mic-chunker");
  node.port.onmessage = (e) => window.mic.chunk(e.data);
  ctx.createMediaStreamSource(stream).connect(node);
  // Keep the graph pulling without making a sound.
  const mute = ctx.createGain();
  mute.gain.value = 0;
  node.connect(mute).connect(ctx.destination);
  stream.getAudioTracks()[0]?.addEventListener("ended", async () => {
    await stop();
    window.mic.status({ state: "ended" });
  });
  return label();
}

function label() {
  return stream?.getAudioTracks()[0]?.label || "microphone";
}

// The Mac's input changed (AirPods connected, a USB mic plugged in…): Mercy
// follows macOS's choice, so ask main to restart on the new default.
let lastDefault = null;
navigator.mediaDevices.addEventListener("devicechange", async () => {
  const devices = await navigator.mediaDevices.enumerateDevices();
  const def = devices.find((d) => d.kind === "audioinput" && d.deviceId === "default")?.label ?? null;
  if (ctx && lastDefault !== null && def !== lastDefault) {
    await stop();
    window.mic.status({ state: "ended", reason: "input changed" });
  }
  lastDefault = def;
});
navigator.mediaDevices
  .enumerateDevices()
  .then((d) => (lastDefault = d.find((x) => x.kind === "audioinput" && x.deviceId === "default")?.label ?? null))
  .catch(() => {});

async function stop() {
  stream?.getTracks().forEach((t) => t.stop());
  await ctx?.close();
  ctx = stream = node = null;
}

window.mic.onCommand(async ({ id, cmd }) => {
  try {
    const result = cmd === "start" ? await start() : await stop();
    window.mic.reply(id, { ok: true, result });
  } catch (err) {
    window.mic.reply(id, { ok: false, error: `${err.name}: ${err.message}` });
  }
});

// Test hook: lets a test end the track the way macOS does when the mic goes away.
window.__micTrack = () => stream?.getAudioTracks()[0] ?? null;
