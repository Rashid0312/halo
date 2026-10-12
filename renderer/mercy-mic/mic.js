// Mercy's microphone: a hidden window records with Chromium's echo
// cancellation / noise suppression and streams 16 kHz PCM16 chunks to main.
let ctx = null;
let stream = null;
let node = null;

async function start() {
  if (ctx) return;
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
  const label = stream.getAudioTracks()[0]?.label ?? "microphone";
  stream.getAudioTracks()[0]?.addEventListener("ended", () => window.mic.status({ state: "ended" }));
  return label;
}

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
