// On-device speech models (sherpa-onnx): keyword spotter, speaker embeddings,
// VAD. Downloaded by `npm run models` into ./models.
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { RESOURCES } from "./paths.js";

export const SAMPLE_RATE = 16000;
const DIR = path.join(RESOURCES, "models");
const KWS = path.join(DIR, "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01");
const kwsFile = (part) => path.join(KWS, `${part}-epoch-12-avg-2-chunk-16-left-64.int8.onnx`);

export const MODEL_FILES = {
  speaker: path.join(DIR, "nemo_en_titanet_small.onnx"),
  vad: path.join(DIR, "silero_vad.onnx"),
  keywords: path.join(DIR, "keywords.txt"),
  kwsEncoder: kwsFile("encoder"),
  kwsDecoder: kwsFile("decoder"),
  kwsJoiner: kwsFile("joiner"),
  kwsTokens: path.join(KWS, "tokens.txt"),
};

export function modelsReady() {
  return Object.values(MODEL_FILES).every((f) => fs.existsSync(f));
}

let sherpa = null;
export function loadSherpa() {
  sherpa ??= createRequire(import.meta.url)("sherpa-onnx-node");
  return sherpa;
}

export function createKeywordSpotter() {
  return new (loadSherpa().KeywordSpotter)({
    featConfig: { sampleRate: SAMPLE_RATE, featureDim: 80 },
    modelConfig: {
      transducer: { encoder: MODEL_FILES.kwsEncoder, decoder: MODEL_FILES.kwsDecoder, joiner: MODEL_FILES.kwsJoiner },
      tokens: MODEL_FILES.kwsTokens,
      numThreads: 1,
      provider: "cpu",
      debug: 0,
    },
    keywordsFile: MODEL_FILES.keywords,
    keywordsScore: 1.0,
    keywordsThreshold: 0.25,
  });
}

/**
 * @param {{ minSilence?: number, maxSpeech?: number }} [opts] seconds
 */
export function createVad({ minSilence = 0.5, maxSpeech = 20 } = {}) {
  return new (loadSherpa().Vad)(
    {
      sileroVad: { model: MODEL_FILES.vad, threshold: 0.5, minSilenceDuration: minSilence, minSpeechDuration: 0.25, windowSize: 512, maxSpeechDuration: maxSpeech },
      sampleRate: SAMPLE_RATE,
      numThreads: 1,
      debug: 0,
    },
    60, // buffer seconds
  );
}

export function createSpeakerExtractor() {
  return new (loadSherpa().SpeakerEmbeddingExtractor)({ model: MODEL_FILES.speaker, numThreads: 1, debug: 0 });
}

/** PCM16 LE Buffer → Float32Array in [-1, 1]. */
export function pcm16ToFloat(buf) {
  const n = buf.length >> 1;
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = buf.readInt16LE(i * 2) / 32768;
  return out;
}

/** Plain decimation by an integer factor (48 kHz → 16 kHz), averaging each group. */
export function downsample(x, factor) {
  if (factor === 1) return x;
  const out = new Float32Array(Math.floor(x.length / factor));
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    for (let j = 0; j < factor; j++) s += x[i * factor + j];
    out[i] = s / factor;
  }
  return out;
}

/**
 * Drop leading/trailing silence (20 ms frames quieter than 10% of the loudest
 * frame), so voice matching only sees speech. Keeps a 100 ms margin.
 */
export function trimSilence(x) {
  const F = 320;
  const frames = Math.floor(x.length / F);
  if (frames < 3) return x;
  const e = new Float32Array(frames);
  let max = 0;
  for (let f = 0; f < frames; f++) {
    e[f] = rms(x.subarray(f * F, (f + 1) * F));
    if (e[f] > max) max = e[f];
  }
  const floor = max * 0.1;
  let a = 0;
  let b = frames - 1;
  while (a < b && e[a] < floor) a++;
  while (b > a && e[b] < floor) b--;
  return x.subarray(Math.max(0, (a - 5) * F), Math.min(x.length, (b + 6) * F));
}

export function rms(x) {
  let s = 0;
  for (let i = 0; i < x.length; i++) s += x[i] * x[i];
  return Math.sqrt(s / Math.max(1, x.length));
}
