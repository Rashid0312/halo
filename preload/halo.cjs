// Preload for Halo's floating panel: a small, explicit bridge instead of the
// generated catch-all API. Only the channels below are reachable.
const { contextBridge, ipcRenderer } = require("electron");

const INVOKE = new Set([
  "halo:getState",
  "halo:toggleTalk",
  "halo:askText",
  "halo:solveScreen",
  "halo:hide",
  "halo:autoHide",
  "halo:quit",
  "halo:resize",
  "halo:setVoiceEnabled",
  "halo:permissionReply",
  "halo:playback",
  "halo:wakeState",
  "halo:setWake",
  "halo:enrollStart",
  "halo:enrollCancel",
  "halo:voiceDelete",
  "halo:keysState",
  "halo:setKeys",
  "halo:openKeyConsole",
  "halo:getOpenAtLogin",
  "halo:setOpenAtLogin",
  "halo:showLogs",
  "halo:updateInfo",
  "halo:openUpdate",
]);
const EVENTS = new Set([
  "halo:state",
  "halo:asked",
  "halo:permission",
  "halo:permission:closed",
  "halo:audio",
  "halo:audioStop",
  "halo:wake",
  "halo:enroll",
  "halo:openComposer",
  "halo:startEnroll",
  "halo:trayHidden",
  "halo:speak",
  "halo:update",
  "speech:realtime-frame:received",
]);

contextBridge.exposeInMainWorld("halo", {
  invoke: async (channel, payload) => {
    if (!INVOKE.has(channel)) throw new Error(`blocked channel ${channel}`);
    const res = await ipcRenderer.invoke(channel, payload);
    if (res && typeof res === "object" && "ok" in res) {
      if (!res.ok) throw new Error(res.error?.message ?? "ipc failed");
      return res.value;
    }
    return res;
  },
  on: (channel, cb) => {
    if (!EVENTS.has(channel)) throw new Error(`blocked event ${channel}`);
    const handler = (_e, payload) => cb(payload);
    ipcRenderer.on(channel, handler);
    return () => ipcRenderer.removeListener(channel, handler);
  },
});
