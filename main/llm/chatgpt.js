// ChatGPT brain: OpenAI's Responses API, paid by the user's ChatGPT plan
// through "Sign in with ChatGPT" (./chatgpt-auth.js). Same interface as
// ./deepseek.js — Chat-style messages in, { type: "text" } / { type: "tool_calls" }
// events out — so brain.js doesn't care which brain answers.
//
// Plan-usage rules (developers.openai.com/siwc/…/preview-limitations):
// store:false + stream:true, the system prompt goes in `instructions`, history
// is resent in `input`, and temperature / max_output_tokens are not allowed.
import { chatgptAccessToken, RESOURCE } from "./chatgpt-auth.js";
import { store } from "../store.js";
import { log } from "../log.js";

let models = null; // [{ slug, name }] for the signed-in account
const noReasoning = new Set(); // models that rejected the reasoning option

/** Models this ChatGPT account can use here, as [{ slug, name }]. */
export async function listModels({ fresh = false } = {}) {
  if (models && !fresh) return models;
  const res = await fetch(`${RESOURCE}/models`, { headers: { Authorization: `Bearer ${await chatgptAccessToken()}` } });
  if (!res.ok) throw new Error(`ChatGPT models: ${res.status} ${(await res.text().catch(() => "")).slice(0, 200)}`);
  const body = await res.json();
  models = (body.models ?? body.data ?? []).filter((m) => (m.visibility ?? "list") === "list").map((m) => ({ slug: m.slug ?? m.id, name: m.display_name ?? m.slug ?? m.id }));
  return models;
}

export function forgetModels() {
  models = null;
}

/** The chosen model, or the account's first one. */
async function pickModel() {
  const chosen = store.get("brain")?.chatgptModel;
  const list = await listModels();
  if (chosen && list.some((m) => m.slug === chosen)) return chosen;
  if (!list.length) throw new Error("Your ChatGPT account has no models Mercy can use");
  return list[0].slug;
}

/** Chat-style messages → { instructions, input } for the Responses API. */
function toResponses(messages) {
  const instructions = [];
  const input = [];
  for (const m of messages) {
    if (m.role === "system") instructions.push(m.content);
    else if (m.role === "user") {
      const parts = typeof m.content === "string" ? [{ type: "text", text: m.content }] : m.content;
      input.push({
        role: "user",
        content: parts.map((p) => (p.type === "image_url" ? { type: "input_image", image_url: p.image_url.url } : { type: "input_text", text: p.text })),
      });
    } else if (m.role === "assistant") {
      if (m.content) input.push({ role: "assistant", content: [{ type: "output_text", text: m.content }] });
      for (const c of m.tool_calls ?? []) input.push({ type: "function_call", call_id: c.id, name: c.function.name, arguments: c.function.arguments || "{}" });
    } else if (m.role === "tool") {
      input.push({ type: "function_call_output", call_id: m.tool_call_id, output: m.content });
    }
  }
  return { instructions: instructions.join("\n\n"), input };
}

const toolDef = (t) => ({ type: "function", name: t.function.name, description: t.function.description, parameters: t.function.parameters });

/** A readable message for plan-usage errors (developers.openai.com/siwc/…/errors-and-recovery). */
function explain(code, fallback) {
  switch (code) {
    case "subscription_sharing_user_not_eligible":
      return "Your ChatGPT plan can't be used by Mercy — it needs ChatGPT Plus or Pro. Switch the brain back to DeepSeek under ···.";
    case "subscription_sharing_usage_limit_exceeded":
      return "You've used up your ChatGPT plan's usage for now. Check it at chatgpt.com → Settings → Usage, or switch the brain to DeepSeek under ···.";
    case "subscription_sharing_usage_unavailable":
    case "subscription_sharing_user_unavailable":
      return "ChatGPT couldn't check your plan just now — try again in a moment.";
    default:
      return `ChatGPT: ${fallback}`;
  }
}

async function post(body, signal) {
  const token = await chatgptAccessToken();
  const send = (b) =>
    fetch(`${RESOURCE}/responses`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(b),
      signal,
    });
  let res = await send(body);
  if (res.ok) return res;
  let text = await res.text().catch(() => "");
  let err = {};
  try {
    const j = JSON.parse(text);
    err = j.error ?? { message: j.detail };
  } catch {}
  // A model that doesn't take a reasoning setting: drop it and remember.
  if (res.status === 400 && body.reasoning && /reasoning/.test(`${err.param ?? ""} ${err.message ?? ""}`)) {
    log.info(`[chatgpt] ${body.model} doesn't take a reasoning setting — sending without`);
    noReasoning.add(body.model);
    res = await send({ ...body, reasoning: undefined });
    if (res.ok) return res;
    text = await res.text().catch(() => "");
    try {
      err = JSON.parse(text).error ?? {};
    } catch {}
  }
  throw new Error(explain(err.code, `${res.status} ${err.message ?? text.slice(0, 300)}`));
}

/**
 * Streamed answer with optional tools. Yields { type: "text", delta } as text
 * arrives, then one { type: "tool_calls", calls: [{ id, name, arguments }] } if
 * the model called tools. `maxTokens` and `temperature` are ignored (plan usage
 * doesn't allow them).
 * @param {{ model?: string, effort?: string, messages: object[], tools?: object[], signal?: AbortSignal }} opts
 */
export async function* streamChat({ model, effort = "low", messages, tools, signal }) {
  const slug = model ?? (await pickModel());
  const { instructions, input } = toResponses(messages);
  const res = await post(
    {
      model: slug,
      instructions,
      input,
      store: false,
      stream: true,
      ...(tools?.length ? { tools: tools.map(toolDef) } : {}),
      ...(effort && !noReasoning.has(slug) ? { reasoning: { effort } } : {}),
    },
    signal,
  );
  const decoder = new TextDecoder();
  const calls = [];
  let buf = "";
  let completed = false;
  for await (const chunk of res.body) {
    buf += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") continue;
      const ev = JSON.parse(data);
      if (ev.type === "response.output_text.delta") yield { type: "text", delta: ev.delta };
      else if (ev.type === "response.output_item.done" && ev.item?.type === "function_call") {
        calls.push({ id: ev.item.call_id, name: ev.item.name, arguments: ev.item.arguments });
      } else if (ev.type === "response.completed") completed = true;
      else if (ev.type === "response.failed" || ev.type === "error") {
        const e = ev.response?.error ?? ev.error ?? ev;
        throw new Error(explain(e.code, e.message ?? "the answer failed"));
      } else if (ev.type === "response.incomplete") {
        throw new Error(`ChatGPT stopped early (${ev.response?.incomplete_details?.reason ?? "incomplete"})`);
      }
    }
  }
  if (!completed) throw new Error("ChatGPT's answer was cut off — try again");
  if (calls.length) yield { type: "tool_calls", calls };
}
