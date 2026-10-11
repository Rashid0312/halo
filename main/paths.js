import path from "node:path";
import { fileURLToPath } from "node:url";

// The app's source root (inside app.asar when installed).
export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Files that other programs read (osascript scripts) live outside the asar archive.
export const UNPACKED = ROOT.replace(/app\.asar$/, "app.asar.unpacked");

// Installed app: models and the Touch Bar helper are in Contents/Resources.
// Development: they're in the repo (models/, native/touchbar/).
export const PACKAGED = ROOT.endsWith("app.asar");
export const RESOURCES = PACKAGED ? process.resourcesPath : ROOT;
