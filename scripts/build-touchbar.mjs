// Builds the Touch Bar helper (native/touchbar/mercy-touchbar) with swiftc.
//
//   npm run touchbar
//
// Mercy also builds it automatically on launch in development; the packaged
// app ships it prebuilt (npm run dist runs this first).
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "native", "touchbar");
execFileSync("swiftc", ["-O", path.join(DIR, "MercyTouchBar.swift"), "-o", path.join(DIR, "mercy-touchbar")], { stdio: "inherit" });
console.log("built native/touchbar/mercy-touchbar");
