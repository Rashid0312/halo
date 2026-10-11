// Builds the Touch Bar helper (native/touchbar/halo-touchbar) with swiftc.
//
//   npm run touchbar
//
// Halo also builds it automatically on launch in development; the packaged
// app ships it prebuilt (npm run dist runs this first).
import { execFileSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "native", "touchbar");
execFileSync("swiftc", ["-O", path.join(DIR, "HaloTouchBar.swift"), "-o", path.join(DIR, "halo-touchbar")], { stdio: "inherit" });
console.log("built native/touchbar/halo-touchbar");
