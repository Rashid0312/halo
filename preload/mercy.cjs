// Preload for Mercy's floating panel: a small, explicit bridge instead of the
// generated catch-all API. Only the channels below are reachable.
const { contextBridge, ipcRenderer } = require("electron");

const INVOKE = new Set([
  "mercy:getState",
  "mercy:toggleTalk",
  "mercy:askText",
  "mercy:solveScreen",
  "mercy:hide",
  "mercy:autoHide",
  "mercy:quit",
  "mercy:resize",
  "mercy:setVoiceEnabled",
  "mercy:permissionReply",
  "mercy:getTrust",
  "mercy:setTrust",
  "mercy:forgetAlways",
  "mercy:playback",
  "mercy:wakeState",
  "mercy:setWake",
  "mercy:enrollStart",
  "mercy:enrollCancel",
  "mercy:voiceDelete",
  "mercy:keysState",
  "mercy:setKeys",
  "mercy:openKeyConsole",
  "mercy:getOpenAtLogin",
  "mercy:setOpenAtLogin",
  "mercy:showLogs",
  "mercy:level",
  "mercy:updateInfo",
  "mercy:openUpdate",
  "speech:getEngine",
  "speech:setEngine",
]);
const EVENTS = new Set([
  "mercy:state",
  "mercy:asked",
  "mercy:permission",
  "mercy:permission:closed",
  "mercy:audio",
  "mercy:audioStop",
  "mercy:wake",
  "mercy:enroll",
  "mercy:openComposer",
  "mercy:startEnroll",
  "mercy:trayHidden",
  "mercy:speak",
  "mercy:update",
  "speech:realtime-frame:received",
]);

contextBridge.exposeInMainWorld("mercy", {
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
