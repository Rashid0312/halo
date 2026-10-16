// Opt-in test recordings of the user's own requests, for `npm run eval -- mine`.
// Off unless the user turns it on (panel ··· → Record my next 20 requests);
// then each request's microphone audio — exactly what the speech engine got —
// is saved with what Mercy heard, in <userData>/stt-samples/. Never uploaded.
import { app } from "electron";
import fs from "node:fs";
import path from "node:path";
import { store } from "../store.js";
import { log } from "../log.js";

export const SAMPLE_COUNT = 20;
const RATE = 16000;

export const samplesDir = () => path.join(app.getPath("userData"), "stt-samples");

const prefs = () => store.get("stt") ?? {};

/** Requests still to record (0 = off). */
export const recordingLeft = () => Math.max(0, Number(prefs().record) || 0);

function wav(pcm) {
  const h = Buffer.alloc(44);
  h.write("RIFF", 0);
  h.writeUInt32LE(36 + pcm.length, 4);
  h.write("WAVEfmt ", 8);
  h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20); // PCM
  h.writeUInt16LE(1, 22); // mono
  h.writeUInt32LE(RATE, 24);
  h.writeUInt32LE(RATE * 2, 28);
  h.writeUInt16LE(2, 32);
  h.writeUInt16LE(16, 34);
  h.write("data", 36);
  h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

/** @param {Buffer} pcm  @param {{ heard: string, engine: string, via: string }} meta */
export function saveSample(pcm, meta) {
  const left = recordingLeft();
  if (!left || !pcm?.length) return;
  const dir = samplesDir();
  fs.mkdirSync(dir, { recursive: true });
  const name = new Date().toISOString().replace(/[:.]/g, "-");
  fs.writeFileSync(path.join(dir, `${name}.wav`), wav(pcm));
  fs.writeFileSync(path.join(dir, `${name}.json`), JSON.stringify({ ...meta, said: null, seconds: +(pcm.length / 2 / RATE).toFixed(2) }, null, 2));
  store.set("stt", { ...prefs(), record: left - 1 });
  log.info(`[stt] saved sample ${SAMPLE_COUNT - left + 1}/${SAMPLE_COUNT}`);
}

export function samplesState() {
  let saved = 0;
  try {
    saved = fs.readdirSync(samplesDir()).filter((f) => f.endsWith(".wav")).length;
  } catch {}
  return { left: recordingLeft(), saved };
}

export function registerSamples(gateway) {
  gateway.handleAll({
    "mercy:samplesState": () => samplesState(),
    "mercy:setRecording": (on) => {
      store.set("stt", { ...prefs(), record: on ? SAMPLE_COUNT : 0 });
      return samplesState();
    },
    "mercy:deleteSamples": () => {
      fs.rmSync(samplesDir(), { recursive: true, force: true });
      store.set("stt", { ...prefs(), record: 0 });
      return samplesState();
    },
  });
}
