// Builds the native helpers with swiftc:
//   native/touchbar/mercy-touchbar  — the Touch Bar button
//   native/speech/mercy-speech      — on-device speech recognition
//
//   npm run native
//
// Mercy also builds them automatically on launch in development; the packaged
// app ships them prebuilt (npm run dist runs this first).
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const NATIVE = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "native");
for (const [dir, source, binary] of [
  ["touchbar", "MercyTouchBar.swift", "mercy-touchbar"],
  ["speech", "MercySpeech.swift", "mercy-speech"],
]) {
  execFileSync("swiftc", ["-O", path.join(NATIVE, dir, source), "-o", path.join(NATIVE, dir, binary)], { stdio: "inherit" });
  console.log(`built native/${dir}/${binary}`);
}
