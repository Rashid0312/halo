// Preload for the hidden mic window: commands in, PCM chunks out.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("mic", {
  onCommand: (cb) => ipcRenderer.on("mic:command", (_e, msg) => cb(msg)),
  reply: (id, res) => ipcRenderer.send("mic:reply", id, res),
  chunk: (buf) => ipcRenderer.send("mic:chunk", buf),
  status: (s) => ipcRenderer.send("mic:status", s),
});
