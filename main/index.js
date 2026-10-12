import "dotenv/config";
import { app, powerMonitor, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { Gateway } from "./gateway.js";
import { WindowRegistry } from "./windows.js";
import { initStore, store } from "./store.js";
import { log, logFile } from "./log.js";
import { SessionService } from "./session.js";
import { AudioService } from "./audio.js";
import { Realtime } from "./realtime.js";
import { SpeechService } from "./speech.js";
import { Brain } from "./brain.js";
import { ScreenService } from "./screen.js";
import { VoiceService } from "./voice.js";
import { Permissions } from "./permissions.js";
import { WakeService } from "./wake.js";
import { TrayService } from "./tray.js";
import { PillService } from "./pill.js";
import { TouchBarService } from "./touchbar.js";
import { loadKeys, keysState, registerKeys } from "./keys.js";
import { UpdateService } from "./updates.js";

// Dev/test hook: MERCY_USER_DATA=/tmp/dir keeps test runs out of the real profile.
if (process.env.MERCY_USER_DATA) app.setPath("userData", process.env.MERCY_USER_DATA);

// Mercy used to be called Halo: bring the settings over once. Keys and the
// voice profile are encrypted with Halo's Keychain entry, so those are set up
// again (Mercy asks).
{
  const dir = app.getPath("userData");
  const old = path.join(path.dirname(dir), "Halo", "store.json");
  if (!process.env.MERCY_USER_DATA && !fs.existsSync(path.join(dir, "store.json")) && fs.existsSync(old)) {
    fs.mkdirSync(dir, { recursive: true });
    fs.copyFileSync(old, path.join(dir, "store.json"));
  }
}

// One Mercy at a time: a second launch just opens the panel of the running one.
if (!app.requestSingleInstanceLock()) app.exit(0);

// Self-healing: an unexpected error restarts Mercy — unless it already crashed
// right after a restart (then stay down instead of looping).
const relaunched = process.argv.includes("--relaunched");
process.on("uncaughtException", (err) => {
  log.error(`[crash] ${err?.stack ?? err}`);
  if (relaunched && process.uptime() < 60) return app.exit(1);
  app.relaunch({ args: [...process.argv.slice(1).filter((a) => a !== "--relaunched"), "--relaunched"] });
  app.exit(1);
});
process.on("unhandledRejection", (err) => log.error(`[unhandled] ${err?.stack ?? err}`));

/** Open at login — only for the installed app (never registers the dev Electron binary). */
function setOpenAtLogin(on) {
  store.set("ui", { ...(store.get("ui") ?? {}), openAtLogin: on });
  if (app.isPackaged) app.setLoginItemSettings({ openAtLogin: on });
  else log.info(`[login] open at login → ${on} (applies to the installed app only)`);
}
function openAtLogin() {
  return app.isPackaged ? app.getLoginItemSettings().openAtLogin : Boolean(store.get("ui")?.openAtLogin ?? true);
}

app.whenReady().then(async () => {
  const registry = new WindowRegistry();
  const gateway = new Gateway(registry);
  initStore();
  log.info(`[boot] Mercy ${app.getVersion()}${relaunched ? " (restarted after a crash)" : ""}`);
  // A menu bar app: no Dock icon (the ring, pill and Touch Bar button are its face).
  app.dock?.hide();
  // First run of the installed app: start at login by default.
  if (app.isPackaged && store.get("ui")?.openAtLogin === undefined) setOpenAtLogin(true);
  await loadKeys();
  registerKeys(gateway);
  const session = new SessionService(gateway, registry);
  session.register();
  const audio = new AudioService(gateway, registry);
  audio.register();
  const realtime = new Realtime(gateway);
  const speech = new SpeechService(gateway, realtime, audio, session);
  speech.register();
  const permissions = new Permissions(gateway);
  permissions.register();
  const brain = new Brain(realtime, session, permissions);
  brain.register();
  const screenService = new ScreenService(realtime, session, brain);
  const voice = new VoiceService(gateway, realtime, brain, session, speech, permissions);
  voice.audio = audio; // end-of-speech detection for button / Touch Bar listening
  voice.register();
  const wake = new WakeService(gateway, audio, speech, voice);
  const tray = new TrayService(session, voice, wake, gateway);
  tray.register();
  tray.loginItem = { get: openAtLogin, set: setOpenAtLogin };
  tray.showLogs = () => logFile() && shell.showItemInFolder(logFile());
  new UpdateService(gateway).register();
  const touchbar = new TouchBarService(voice, realtime, wake, gateway);
  touchbar.register().catch((err) => log.warn(`[touchbar] ${err.message}`));
  // The pill stays hidden while the Touch Bar strip shows Mercy.
  const pill = new PillService(registry, session, voice, wake, gateway);
  pill.touchbar = touchbar;
  pill.register();
  permissions.showPanel = () => session.showPanel();
  wake
    .register()
    .then(() => {
      // First run: open the panel so "Connect Mercy" / "Teach Mercy your voice" is seen.
      if (!keysState().ready || (wake.available && !wake.voiceprint.enrolled)) session.showPanel();
    })
    .catch((err) => log.error(`[wake] ${err.message}`));

  // Stop the mic, sockets and helpers before exiting.
  let shuttingDown = false;
  app.on("before-quit", (event) => {
    if (shuttingDown) return;
    event.preventDefault();
    shuttingDown = true;
    voice.unregister();
    touchbar.stop();
    Promise.resolve()
      .then(() => wake.stop())
      .then(() => session.end())
      .then(() => speech.stop())
      .then(() => audio.shutdown())
      .catch((err) => log.error(`[quit] ${err}`))
      .finally(() => app.exit(0));
  });

  gateway.handleAll({
    "mercy:getOpenAtLogin": () => openAtLogin(),
    "mercy:setOpenAtLogin": (on) => (setOpenAtLogin(Boolean(on)), openAtLogin()),
    "mercy:showLogs": () => logFile() && shell.showItemInFolder(logFile()),
  });
  app.on("second-instance", () => {
    log.info("[app] Mercy was opened again → showing the panel");
    session.showPanel({ focus: true });
    gateway.broadcast("mercy:openComposer", null, { to: ["panel"] });
  });
  // After sleep the mic and sockets may be gone: get listening again.
  powerMonitor.on("resume", () => wake.restartMic("woke from sleep"));
  audio.onEnded(() => setTimeout(() => wake.restartMic("mic stopped"), 1000));

  // Test hooks for self-healing: MERCY_TEST="resume@2000,crash@6000" (ms after launch).
  for (const ev of (process.env.MERCY_TEST ?? "").split(",").filter(Boolean)) {
    const [what, ms] = ev.split("@");
    setTimeout(() => {
      if (what === "resume") powerMonitor.emit("resume");
      if (what === "crash") throw new Error("test crash (MERCY_TEST)");
    }, Number(ms));
  }

  // "Look at my screen" tile.
  gateway.handle("mercy:solveScreen", () => screenService.solve());

  // Mercy lives in the menu bar; the panel is created hidden and drops down
  // from the icon (click, "Hey Mercy", or a running request).
  const panel = session.createPanel();

  // Dev hook: MERCY_SCRIPT=/path/to/file.js runs in the panel after load.
  if (process.env.MERCY_SCRIPT) {
    panel.webContents.once("did-finish-load", async () => {
      try {
        const src = fs.readFileSync(process.env.MERCY_SCRIPT, "utf8");
        const out = await panel.webContents.executeJavaScript(src);
        log.info(`[script] ${JSON.stringify(out)}`);
      } catch (err) {
        log.error(`[script] ${err}`);
      }
    });
  }
});

app.on("window-all-closed", () => app.quit());
// Ctrl+C / kill → graceful quit path instead of an abrupt exit mid-capture.
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => app.quit());
