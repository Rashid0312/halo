// Halo's hosted OAuth callback. A provider sends the browser here after the
// user approves; this hands the result to the Halo app at halo://oauth/callback.
//
// Stateless by design: it stores nothing, logs nothing, and never sees a token.
// It forwards only the one-time authorization code (useless without the PKCE
// verifier that never leaves the Mac) and the state, which the app matches to
// the sign-in it started. Here state can only be checked for shape.

const APP_CALLBACK = "halo://oauth/callback";
const STATE = /^[A-Za-z0-9._~-]{16,512}$/;
const ERROR = /^[a-z_]{1,64}$/;

const HEADERS = {
  "Cache-Control": "no-store",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'",
};

/** Turns a callback request URL into the response to send: { status, headers, body }. */
export function forward(method, requestURL) {
  const url = new URL(requestURL);
  if (method !== "GET" || url.pathname !== "/oauth/callback") {
    return page(404, "Nothing here", "This address only completes sign-in for the Halo app.");
  }
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code");
  const error = url.searchParams.get("error");
  if (!STATE.test(state) || (code === null) === (error === null) || (code !== null && (code.length === 0 || code.length > 4096))) {
    return page(400, "This sign-in link isn't valid", "Close this tab and start again from Halo.");
  }
  const next = new URLSearchParams({ state });
  if (code !== null) next.set("code", code);
  else next.set("error", ERROR.test(error) ? error : "access_denied");
  // A redirect (not a page that navigates) keeps the user's click on "Allow"
  // as the gesture that lets the browser open the app.
  return { status: 302, headers: { ...HEADERS, Location: `${APP_CALLBACK}?${next}` }, body: "" };
}

function page(status, title, detail) {
  const body = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Halo</title><style>
:root{color-scheme:light dark}body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f}
@media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}.card{background:#2c2c2e!important}}
.card{background:#fff;border-radius:18px;padding:40px 44px;max-width:420px;text-align:center;box-shadow:0 10px 40px rgba(0,0,0,.08)}
.mark{width:56px;height:56px;margin:0 auto 18px;border-radius:50%;background:radial-gradient(circle at 35% 30%,#a5b4fc,#6366f1 60%,#4338ca)}
h1{font-size:20px;margin:0 0 8px}p{margin:0;opacity:.7;line-height:1.45}
</style></head><body><div class="card"><div class="mark"></div><h1>${title}</h1><p>${detail}</p></div></body></html>`;
  return { status, headers: { ...HEADERS, "Content-Type": "text/html; charset=utf-8" }, body };
}
