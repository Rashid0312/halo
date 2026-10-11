// "Only my voice": an on-device speaker profile, modeled on Apple's
// Personalized "Hey Siri".
//
// - Explicit enrollment: "Hey Halo" ×5 (for the trigger) + 3 short sentences
//   (so whole requests match too) → 8 speaker vectors.
// - Implicit enrollment: requests that clearly match add their vector over
//   time (max 35), so the profile learns other rooms, mics and moods.
// - Score = mean of the top-3 cosine similarities to the profile.
// - Two checks: the "Hey Halo" trigger (~1 s) and the whole request (longer,
//   more reliable). Thresholds were picked on real speakers (Mini LibriSpeech,
//   unseen speakers: 0% false reject, 1.5% false accept) and made a bit stricter.
//
// The profile never leaves the Mac: it's encrypted with the macOS Keychain
// (Electron safeStorage) in userData/voiceprint.bin. No audio is stored.
import { app, safeStorage } from "electron";
import fs from "node:fs";
import path from "node:path";
import { createSpeakerExtractor, rms, SAMPLE_RATE, trimSilence } from "./ondevice.js";
import { log } from "./log.js";

export const THRESHOLDS = {
  trigger: 0.35, // "Hey Halo" alone (silence-trimmed)
  request: 0.35, // the whole spoken request
  learn: 0.55, // request this confident → add to the profile
};
const ENROLL_PHRASES = 5;
const SENTENCES = [
  "What's the weather like this weekend?",
  "Remind me to call my sister tomorrow morning.",
  "Open my calendar and show me next week.",
];
const ENROLL_CLIPS = ENROLL_PHRASES + SENTENCES.length;

/** What to say for clip number `i` (0-based). */
export function enrollPrompt(i) {
  return i < ENROLL_PHRASES ? "Hey Halo" : SENTENCES[i - ENROLL_PHRASES];
}
const MAX_IMPLICIT = 35;

const dot = (a, b) => {
  let d = 0;
  for (let i = 0; i < a.length; i++) d += a[i] * b[i];
  return d;
};

export class Voiceprint {
  constructor() {
    this.file = path.join(app.getPath("userData"), "voiceprint.bin");
    this.extractor = null;
    this.profile = null; // { version, explicit: number[][], implicit: number[][], createdAt }
    this.enrolling = null; // number[][] while enrolling
  }

  get enrolled() {
    return Boolean(this.profile?.explicit?.length >= ENROLL_CLIPS);
  }

  vectors() {
    return [...(this.profile?.explicit ?? []), ...(this.profile?.implicit ?? [])];
  }

  async load() {
    if (!fs.existsSync(this.file)) return;
    try {
      const { result, shouldReEncrypt } = await safeStorage.decryptStringAsync(fs.readFileSync(this.file));
      this.profile = JSON.parse(result);
      if (shouldReEncrypt) await this.save();
      log.info(`[voiceprint] loaded (${this.profile.explicit.length} enrolled + ${this.profile.implicit.length} learned)`);
    } catch (err) {
      log.error(`[voiceprint] could not read profile: ${err.message}`);
      this.profile = null;
    }
  }

  async save() {
    if (!(await safeStorage.isAsyncEncryptionAvailable())) {
      // Never write a voiceprint unencrypted; keep it in memory for this run.
      log.warn("[voiceprint] Keychain encryption unavailable — profile kept in memory only");
      return;
    }
    const enc = await safeStorage.encryptStringAsync(JSON.stringify(this.profile));
    fs.writeFileSync(this.file, enc, { mode: 0o600 });
  }

  /** @param {Float32Array} samples 16 kHz mono */
  embed(samples) {
    this.extractor ??= createSpeakerExtractor();
    const s = this.extractor.createStream();
    s.acceptWaveform({ sampleRate: SAMPLE_RATE, samples });
    s.inputFinished();
    const e = Float32Array.from(this.extractor.compute(s, false));
    const n = Math.hypot(...e) || 1;
    return Array.from(e, (v) => v / n);
  }

  /** Mean of the top-3 similarities to the profile (0 when not enrolled). */
  score(vec) {
    const sims = this.vectors()
      .map((p) => dot(p, vec))
      .sort((a, b) => b - a);
    if (!sims.length) return 0;
    const top = sims.slice(0, 3);
    return top.reduce((a, b) => a + b, 0) / top.length;
  }

  /**
   * @param {Float32Array} samples
   * @param {"trigger" | "request"} kind
   * @returns {{ ok: boolean, score: number, vec: number[] }}
   */
  verify(samples, kind) {
    if (!this.enrolled) return { ok: false, score: 0, vec: null };
    const vec = this.embed(trimSilence(samples));
    const score = this.score(vec);
    return { ok: score > THRESHOLDS[kind], score, vec };
  }

  /** Implicit enrollment: only clearly-matching requests teach the profile. */
  async learn(vec, score) {
    if (!this.enrolled || !vec || score < THRESHOLDS.learn) return;
    this.profile.implicit.push(vec);
    if (this.profile.implicit.length > MAX_IMPLICIT) this.profile.implicit.shift();
    await this.save();
    log.info(`[voiceprint] learned (score ${score.toFixed(2)}, ${this.profile.implicit.length} learned)`);
  }

  // ── explicit enrollment ──────────────────────────────────────────────
  startEnroll() {
    this.enrolling = [];
    return { count: 0, needed: ENROLL_CLIPS, prompt: enrollPrompt(0) };
  }

  /**
   * One enrollment recording ("Hey Halo" or a sentence). Rejects clips that are
   * too short, too quiet, or don't sound like the earlier ones (someone else,
   * or mostly noise).
   */
  async addEnrollClip(samples) {
    if (!this.enrolling) return { ok: false, reason: "not enrolling" };
    const count0 = this.enrolling.length;
    const phrase = count0 < ENROLL_PHRASES;
    const retry = (reason) => ({ ok: false, reason, count: count0, needed: ENROLL_CLIPS, prompt: enrollPrompt(count0) });
    const sec = samples.length / SAMPLE_RATE;
    if (sec < (phrase ? 0.4 : 1)) return retry(phrase ? "Too short — say “Hey Halo” clearly." : "Too short — read the whole sentence.");
    if (sec > (phrase ? 4 : 10)) return retry(phrase ? "Too long — just “Hey Halo”." : "Too long — just that one sentence.");
    if (rms(samples) < 0.01) return retry("Too quiet — move a little closer.");
    const vec = this.embed(samples);
    if (count0 >= 2) {
      const sims = this.enrolling.map((p) => dot(p, vec));
      const mean = sims.reduce((a, b) => a + b, 0) / sims.length;
      // Sentences differ from "Hey Halo" in content, so allow a lower match.
      if (mean < (phrase ? 0.3 : 0.2)) return retry("That didn't sound like the others — try again.");
    }
    this.enrolling.push(vec);
    const count = this.enrolling.length;
    if (count < ENROLL_CLIPS) return { ok: true, count, needed: ENROLL_CLIPS, prompt: enrollPrompt(count) };
    this.profile = { version: 1, explicit: this.enrolling, implicit: [], createdAt: Date.now() };
    this.enrolling = null;
    await this.save();
    log.info("[voiceprint] enrolled");
    return { ok: true, count, needed: ENROLL_CLIPS, done: true };
  }

  cancelEnroll() {
    this.enrolling = null;
  }

  async delete() {
    this.profile = null;
    this.enrolling = null;
    fs.rmSync(this.file, { force: true });
    log.info("[voiceprint] deleted");
  }
}
