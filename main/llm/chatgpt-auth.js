// "Sign in with ChatGPT": the user's ChatGPT plan pays for Mercy's brain
// instead of an API key. OpenAI's flow for open-source, locally run apps
// (developers.openai.com/siwc/token-sharing-open-source):
//
//   browser → auth.openai.com/authorize (PKCE) → http://127.0.0.1:<port>/auth/callback
//   → code exchange → access token (1 h) + rotating refresh token (30 days)
//
// The first sign-in registers Mercy on this Mac (client_id=dynamic_agent_client →
// an issued oaiapp_… id, kept for later sign-ins). Plan usage needs the
// chatgpt.tokens.use.direct scope; accounts whose plan can't be used here
// (e.g. Free) still sign in, without it.
//
// Credentials are encrypted with the macOS Keychain (Electron safeStorage) in
// userData/chatgpt.bin; the per-install host id is in chatgpt-host.json.
import { app, safeStorage, shell } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { log } from "../log.js";

const ISSUER = "https://auth.openai.com";
const AUTHORIZE_URL = `${ISSUER}/api/accounts/authorize`;
const TOKEN_URL = `${ISSUER}/api/accounts/oauth/token`;
const REVOKE_URL = `${ISSUER}/api/accounts/oauth/revoke`;
const JWKS_URL = `${ISSUER}/.well-known/jwks.json`;
export const RESOURCE = "https://api.openai.com/v1";
const PLAN_SCOPE = "chatgpt.tokens.use.direct";
const SCOPES = `openid profile email offline_access resource.invoke ${PLAN_SCOPE}`;
const PORT = 1455;
const SIGN_IN_TIMEOUT_MS = 5 * 60 * 1000;
const REFRESH_EARLY_MS = 2 * 60 * 1000;
// Refresh errors that mean the refresh token is no good: sign in again.
const DEAD_REFRESH = new Set(["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]);
export const MANAGE_USAGE_URL = "https://chatgpt.com/settings/usage";

const file = (name) => path.join(app.getPath("userData"), name);
const b64url = (buf) => Buffer.from(buf).toString("base64url");

let auth = {}; // { clientId?, email?, idToken?, accessToken?, refreshToken?, expiresAt?, scopes?: string[] }
let refreshing = null;
let pendingSignIn = null;
const listeners = new Set();

/** cb(state) runs after sign-in, sign-out or a lost session. */
export function onChatgptChange(cb) {
  listeners.add(cb);
}
function changed() {
  const s = chatgptState();
  for (const cb of listeners) cb(s);
}

export async function loadChatgpt() {
  if (!fs.existsSync(file("chatgpt.bin"))) return;
  try {
    const { result } = await safeStorage.decryptStringAsync(fs.readFileSync(file("chatgpt.bin")));
    auth = JSON.parse(result);
  } catch (err) {
    log.error(`[chatgpt] could not read saved sign-in: ${err.message}`);
    auth = {};
  }
}

async function persist() {
  const enc = await safeStorage.encryptStringAsync(JSON.stringify(auth));
  fs.writeFileSync(file("chatgpt.bin"), enc, { mode: 0o600 });
}

/** Random, opaque id for this install (never the user's identity). */
function hostId() {
  try {
    return JSON.parse(fs.readFileSync(file("chatgpt-host.json"), "utf8")).hostId;
  } catch {
    const hostId = `urn:uuid:${crypto.randomUUID()}`;
    fs.writeFileSync(file("chatgpt-host.json"), JSON.stringify({ hostId }));
    return hostId;
  }
}

/** { signedIn, email, sharing } — sharing: this account's plan can pay for Mercy. */
export function chatgptState() {
  if (process.env.CHATGPT_ACCESS_TOKEN) return { signedIn: true, email: "CHATGPT_ACCESS_TOKEN", sharing: true };
  const signedIn = Boolean(auth.refreshToken);
  return { signedIn, email: signedIn ? (auth.email ?? "") : "", sharing: signedIn && (auth.scopes ?? []).includes(PLAN_SCOPE) };
}

// ── ID token ───────────────────────────────────────────────────────────
let jwks = null;
async function verifyIdToken(idToken, { clientId, nonce }) {
  const [h, p, sig] = idToken.split(".");
  const header = JSON.parse(Buffer.from(h, "base64url"));
  const claims = JSON.parse(Buffer.from(p, "base64url"));
  const findKey = () => jwks?.keys?.find((k) => k.kid === header.kid);
  if (!findKey()) jwks = await (await fetch(JWKS_URL)).json(); // keys rotate: refetch on an unknown kid
  const jwk = findKey();
  if (header.alg !== "RS256" || !jwk) throw new Error("ID token signed with an unknown key");
  const ok = crypto.verify("RSA-SHA256", Buffer.from(`${h}.${p}`), crypto.createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(sig, "base64url"));
  if (!ok) throw new Error("ID token signature is invalid");
  const aud = [].concat(claims.aud);
  if (claims.iss !== ISSUER) throw new Error(`ID token from the wrong issuer (${claims.iss})`);
  if (!aud.includes(clientId)) throw new Error("ID token is for a different app");
  if (claims.exp * 1000 < Date.now() - 60000) throw new Error("ID token expired");
  if (nonce && claims.nonce !== nonce) throw new Error("ID token nonce mismatch");
  return claims;
}

// ── tokens ─────────────────────────────────────────────────────────────
async function tokenRequest(fields) {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(body.error_description || body.error || `token endpoint answered ${res.status}`), { code: body.error, status: res.status });
  return body;
}

/** Keep a token response. Everything is replaced together (the refresh token rotates). */
function keep(tokens, claims) {
  auth = {
    ...auth,
    idToken: tokens.id_token ?? auth.idToken,
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token ?? auth.refreshToken,
    expiresAt: Date.now() + (tokens.expires_in ?? 3600) * 1000,
    scopes: tokens.scope ? String(tokens.scope).split(/\s+/) : auth.scopes,
    ...(claims ? { email: claims.email ?? auth.email, subject: claims.sub } : {}),
  };
}

/** A valid access token for plan usage, refreshed when it's about to expire. */
export async function chatgptAccessToken() {
  // Dev/eval hook: a plan-usage access token from a real sign-in, used as is.
  if (process.env.CHATGPT_ACCESS_TOKEN) return process.env.CHATGPT_ACCESS_TOKEN;
  if (!auth.refreshToken) throw Object.assign(new Error("Not signed in to ChatGPT — sign in under ··· → API keys"), { code: "config" });
  if (auth.accessToken && auth.expiresAt - Date.now() > REFRESH_EARLY_MS) return auth.accessToken;
  refreshing ??= (async () => {
    try {
      const tokens = await tokenRequest({ grant_type: "refresh_token", client_id: auth.clientId, refresh_token: auth.refreshToken, resource: RESOURCE });
      keep(tokens);
      await persist();
      log.info("[chatgpt] token refreshed");
    } catch (err) {
      if (DEAD_REFRESH.has(err.code)) {
        log.warn(`[chatgpt] sign-in expired (${err.code}) — sign in again`);
        await forget();
        throw Object.assign(new Error("Your ChatGPT sign-in expired — sign in again under ··· → API keys"), { code: "config" });
      }
      throw err; // network trouble: keep the credentials, try again next time
    } finally {
      refreshing = null;
    }
  })();
  await refreshing;
  return auth.accessToken;
}

async function forget() {
  const { clientId } = auth;
  auth = clientId ? { clientId } : {}; // keep the registration: next sign-in reuses it
  await persist();
  changed();
}

// ── sign in / out ──────────────────────────────────────────────────────
function listen(port) {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.once("error", reject);
    server.listen(port, "127.0.0.1", () => resolve(server));
  });
}

const page = (title, text) =>
  `<!doctype html><meta charset="utf-8"><title>${title}</title><body style="font:16px -apple-system,system-ui;display:grid;place-items:center;height:90vh;margin:0;background:#111;color:#eee"><div style="text-align:center"><h2>${title}</h2><p>${text}</p></div>`;

/** Open the browser and wait for the user to approve. Resolves to chatgptState(). */
export function signIn() {
  pendingSignIn ??= doSignIn().finally(() => (pendingSignIn = null));
  return pendingSignIn;
}

async function doSignIn() {
  // OpenAI's usual port; any free one works (only the port may differ between sign-ins).
  const server = await listen(PORT).catch((err) => (err.code === "EADDRINUSE" ? listen(0) : Promise.reject(err)));
  const redirectUri = `http://127.0.0.1:${server.address().port}/auth/callback`;
  const verifier = b64url(crypto.randomBytes(32));
  const state = b64url(crypto.randomBytes(16));
  const nonce = b64url(crypto.randomBytes(16));
  const registered = Boolean(auth.clientId);
  const params = new URLSearchParams({
    client_id: registered ? auth.clientId : "dynamic_agent_client",
    ...(registered ? {} : { agent_name_hint: "Mercy" }),
    ext_agent_host_id: hostId(),
    ...(registered && auth.idToken ? { id_token_hint: auth.idToken } : {}),
    ...(registered && auth.email ? { login_hint: auth.email } : {}),
    response_type: "code",
    redirect_uri: redirectUri,
    scope: SCOPES,
    resource: RESOURCE,
    state,
    nonce,
    code_challenge_method: "S256",
    code_challenge: b64url(crypto.createHash("sha256").update(verifier).digest()),
  });

  try {
    const query = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("Sign-in timed out — try again")), SIGN_IN_TIMEOUT_MS);
      server.on("request", (req, res) => {
        const url = new URL(req.url, redirectUri);
        if (url.pathname !== "/auth/callback") return res.writeHead(404).end();
        if (url.searchParams.get("state") !== state) return res.writeHead(400).end("Wrong sign-in attempt.");
        clearTimeout(timer);
        const ok = !url.searchParams.get("error");
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(ok ? page("You're signed in", "You can close this tab and go back to Mercy.") : page("Sign-in cancelled", "You can close this tab."));
        resolve(url.searchParams);
      });
      shell.openExternal(`${AUTHORIZE_URL}?${params}`).catch(reject);
      log.info(`[chatgpt] sign-in opened in the browser (${registered ? "returning" : "first registration"})`);
    });

    if (query.get("error")) {
      throw new Error(query.get("error") === "access_denied" ? "Sign-in was cancelled" : `Sign-in failed: ${query.get("error_description") || query.get("error")}`);
    }
    const clientId = query.get("client_id") || auth.clientId;
    if (!clientId || clientId === "dynamic_agent_client") throw new Error("ChatGPT didn't finish registering Mercy — try again");
    // Keep the registration before the exchange, so a retry reuses it.
    if (clientId !== auth.clientId) {
      auth = { clientId };
      await persist();
    }
    const tokens = await tokenRequest({
      grant_type: "authorization_code",
      client_id: clientId,
      code: query.get("code"),
      code_verifier: verifier,
      redirect_uri: redirectUri,
      resource: RESOURCE,
    });
    const claims = await verifyIdToken(tokens.id_token, { clientId, nonce });
    keep(tokens, claims);
    await persist();
    const s = chatgptState();
    log.info(`[chatgpt] signed in${s.sharing ? " — plan usage on" : " — this plan can't be used by Mercy"}`);
    changed();
    return s;
  } finally {
    server.close();
    server.closeAllConnections?.();
  }
}

export async function signOut() {
  if (auth.refreshToken) {
    // Revoke on OpenAI's side too; local sign-out happens either way.
    await fetch(REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token: auth.refreshToken, token_type_hint: "refresh_token", client_id: auth.clientId }),
    }).catch((err) => log.warn(`[chatgpt] revoke failed: ${err.message}`));
  }
  await forget();
  log.info("[chatgpt] signed out");
  return chatgptState();
}

export function registerChatgpt(gateway) {
  gateway.handleAll({
    "mercy:chatgptState": () => chatgptState(),
    "mercy:chatgptSignIn": () => signIn(),
    "mercy:chatgptSignOut": () => signOut(),
    "mercy:chatgptManageUsage": () => shell.openExternal(MANAGE_USAGE_URL),
  });
}
