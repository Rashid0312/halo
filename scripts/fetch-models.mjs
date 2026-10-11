// Downloads the on-device models for "Hey Halo" + voice recognition into
// ./models (gitignored) and verifies them.
//
//   npm run models
//
// Models (all from the sherpa-onnx releases):
//   - Keyword spotter: sherpa-onnx-kws-zipformer-gigaspeech-3.3M (Apache-2.0)
//   - Speaker embeddings: NVIDIA TitaNet-small (CC-BY-4.0, attribution in README)
//   - Voice activity: Silero VAD (MIT)
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIR = path.join(ROOT, "models");
const REL = "https://github.com/k2-fsa/sherpa-onnx/releases/download";
const KWS = "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01";
const KWS_FILE = (part) => `${part}-epoch-12-avg-2-chunk-16-left-64.int8.onnx`;

const FILES = {
  "nemo_en_titanet_small.onnx": {
    url: `${REL}/speaker-recongition-models/nemo_en_titanet_small.onnx`,
    sha256: "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",
  },
  "silero_vad.onnx": {
    url: `${REL}/asr-models/silero_vad.onnx`,
    sha256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
  },
  [`${KWS}/${KWS_FILE("encoder")}`]: { sha256: "1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678" },
  [`${KWS}/${KWS_FILE("decoder")}`]: { sha256: "e40ff43297abe815e8898494c17e71bba2152d9d40fa3eb803f75d0f7533329a" },
  [`${KWS}/${KWS_FILE("joiner")}`]: { sha256: "eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c" },
  [`${KWS}/tokens.txt`]: { sha256: "fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53" },
};

// "HEY HALO" in the keyword model's BPE tokens (from its bpe.model).
const KEYWORDS = "▁HE Y ▁HA LO @HEY_HALO\n";

const sha256 = (file) => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const ok = (rel) => fs.existsSync(path.join(DIR, rel)) && sha256(path.join(DIR, rel)) === FILES[rel].sha256;

async function download(url, dest) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
}

fs.mkdirSync(DIR, { recursive: true });
for (const [rel, f] of Object.entries(FILES)) {
  if (!f.url || ok(rel)) continue;
  console.log(`downloading ${rel}…`);
  await download(f.url, path.join(DIR, rel));
}

if (Object.keys(FILES).some((rel) => rel.startsWith(KWS) && !ok(rel))) {
  console.log(`downloading ${KWS}…`);
  const tar = path.join(DIR, `${KWS}.tar.bz2`);
  await download(`${REL}/kws-models/${KWS}.tar.bz2`, tar);
  const keep = Object.keys(FILES).filter((rel) => rel.startsWith(KWS));
  execFileSync("tar", ["xjf", tar, "-C", DIR, ...keep]);
  fs.rmSync(tar);
}

for (const rel of Object.keys(FILES)) {
  if (!ok(rel)) throw new Error(`checksum mismatch for models/${rel}`);
}
fs.writeFileSync(path.join(DIR, "keywords.txt"), KEYWORDS);
console.log(`models ready in ${path.relative(process.cwd(), DIR) || "."}`);
