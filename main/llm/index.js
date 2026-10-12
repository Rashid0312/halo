// Mercy's brain: DeepSeek (API key) or ChatGPT (the user's ChatGPT plan, via
// "Sign in with ChatGPT"). Store "brain": { provider: "deepseek" | "chatgpt",
// chatgptModel }. Callers ask for a role — "answer" (spoken/typed requests) or
// "vision" (screenshots) — and the provider picks its model for it.
import * as deepseek from "./deepseek.js";
import * as chatgpt from "./chatgpt.js";
import { chatgptState, onChatgptChange } from "./chatgpt-auth.js";
import { store } from "../store.js";
import { log } from "../log.js";

export const PROVIDERS = ["deepseek", "chatgpt"];
export { imageContent } from "./deepseek.js";

export function brainPrefs() {
  return store.get("brain") ?? { provider: "deepseek" };
}

export function provider() {
  return PROVIDERS.includes(brainPrefs().provider) ? brainPrefs().provider : "deepseek";
}

/**
 * Streamed answer from the chosen brain. Same events either way:
 * { type: "text", delta } …, then { type: "tool_calls", calls } if it called tools.
 * @param {{ role?: "answer" | "vision", messages: object[], tools?: object[], maxTokens?: number, temperature?: number, signal?: AbortSignal }} opts
 */
export function streamChat({ role = "answer", ...opts }) {
  if (provider() === "chatgpt") return chatgpt.streamChat({ ...opts, effort: role === "vision" ? "medium" : "low" });
  return deepseek.streamChat({ ...opts, model: deepseek.MODELS[role] });
}

/** For the UI: which brain, and the ChatGPT models to choose from when it can be used. */
export async function brainState() {
  const s = chatgptState();
  let models = [];
  if (s.sharing) models = await chatgpt.listModels().catch((err) => (log.warn(`[brain] ${err.message}`), []));
  return { provider: provider(), chatgptModel: brainPrefs().chatgptModel ?? models[0]?.slug ?? null, models, chatgpt: s };
}

export function registerBrain(gateway) {
  gateway.handleAll({
    "mercy:getBrain": () => brainState(),
    /** @param {{ provider?: string, model?: string }} next */
    "mercy:setBrain": (next = {}) => {
      const prefs = { ...brainPrefs() };
      if (PROVIDERS.includes(next.provider)) prefs.provider = next.provider;
      if (next.model) prefs.chatgptModel = String(next.model);
      store.set("brain", prefs);
      log.info(`[brain] ${prefs.provider}${prefs.provider === "chatgpt" && prefs.chatgptModel ? ` (${prefs.chatgptModel})` : ""}`);
      return brainState();
    },
  });
  // Another account may have different models.
  onChatgptChange(() => chatgpt.forgetModels());
}
