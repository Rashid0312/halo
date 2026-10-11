// Builds Halo-<version>-arm64.dmg into ./dist.
//
//   npm run dist
//
// electron-builder runs in a temp folder: macOS tags files under iCloud-synced
// folders (like Desktop) with attributes that codesign refuses.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const out = fs.mkdtempSync(path.join(os.tmpdir(), "halo-dist-"));
execFileSync("npx", ["electron-builder", "--mac", "--arm64", `-c.directories.output=${out}`], { cwd: ROOT, stdio: "inherit" });
fs.mkdirSync(path.join(ROOT, "dist"), { recursive: true });
for (const f of fs.readdirSync(out).filter((f) => f.endsWith(".dmg"))) {
  fs.copyFileSync(path.join(out, f), path.join(ROOT, "dist", f));
  console.log(`dist/${f}`);
}
fs.rmSync(out, { recursive: true, force: true });
