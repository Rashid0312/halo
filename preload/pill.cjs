// Preload for the "mic bubble" pill: open the panel, report its size, and
// receive Halo's state.
const { contextBridge, ipcRenderer } = require("electron");

const INVOKE = new Set(["halo:openPanel", "halo:pillResize"]);
const EVENTS = new Set(["halo:state", "halo:wake", "halo:pillOut"]);

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
