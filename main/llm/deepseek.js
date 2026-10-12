// Minimal DeepSeek client (OpenAI-compatible /chat/completions).
// Models on this account: "deepseek-flash" (V4.1-Flash, text+image) and
// "deepseek-v4-pro". Thinking is disabled: it adds ~1.5 s before the first token,
// too slow for a spoken reply.

import { getKey } from "../keys.js";

const BASE = "https://api.deepseek.com";

export const MODELS = {
  // flash: ~1.0s to first token vs ~1.8s for pro, same tool routing on our eval.
  answer: "deepseek-flash",
  answerPro: "deepseek-v4-pro",
  vision: "deepseek-flash", // only V4 model that accepts images
};

function headers() {
  const key = getKey("deepseek");
  if (!key) throw Object.assign(new Error("No DeepSeek key yet — add it in Mercy (··· → API keys)"), { code: "config" });
  return { Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
}

async function post(body, signal, think = false) {
  // think=true: low-effort reasoning (≈+7s before first token, measurably more
  // accurate on bug-finding); default off for live latency.
  const mode = think ? { reasoning_effort: "low" } : { thinking: { type: "disabled" } };
  const res = await fetch(`${BASE}/chat/completions`, {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ ...mode, ...body }),
    signal,
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`DeepSeek ${res.status}: ${text.slice(0, 300)}`);
  }
  return res;
}

/** Streamed completion; yields content deltas. */
export async function* stream(opts) {
  for await (const ev of streamChat(opts)) if (ev.type === "text") yield ev.delta;
}

/**
 * Streamed completion with optional tools. Yields { type: "text", delta } as
 * content arrives, then one { type: "tool_calls", calls: [{ id, name, arguments }] }
 * if the model decided to call tools.
 */
export async function* streamChat({ model, messages, tools, maxTokens = 2000, signal, think = false, temperature }) {
  const res = await post(
    {
      model,
      messages,
      max_tokens: maxTokens,
      stream: true,
      ...(tools?.length ? { tools } : {}),
      ...(temperature !== undefined ? { temperature } : {}),
    },
    signal,
    think,
  );
  const decoder = new TextDecoder();
  const calls = []; // accumulated by index: { id, name, arguments }
  let buf = "";
  const finish = function* () {
    if (calls.length) yield { type: "tool_calls", calls: calls.filter(Boolean) };
  };
  for await (const chunk of res.body) {
    buf += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith("data:")) continue;
      const data = line.slice(5).trim();
      if (data === "[DONE]") return yield* finish();
      const delta = JSON.parse(data).choices?.[0]?.delta ?? {};
      if (delta.content) yield { type: "text", delta: delta.content };
      for (const tc of delta.tool_calls ?? []) {
        const c = (calls[tc.index ?? 0] ??= { id: "", name: "", arguments: "" });
        if (tc.id) c.id = tc.id;
        if (tc.function?.name) c.name += tc.function.name;
        if (tc.function?.arguments) c.arguments += tc.function.arguments;
      }
    }
  }
  yield* finish();
}

/** OpenAI-style content parts for JPEG screenshot(s) + instruction (format verified against deepseek-flash). */
export function imageContent(base64Jpegs, text) {
  return [
    ...base64Jpegs.map((b64) => ({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${b64}` } })),
    { type: "text", text },
  ];
}
