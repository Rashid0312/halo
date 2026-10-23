# Halo OAuth callback

This is Halo's hosted OAuth redirect: `https://auth.<your domain>/oauth/callback`.

Providers send the browser here after the user approves Halo. The handler answers with a 302 to `halo://oauth/callback?code=…&state=…`, which the Mac app handles. The app checks `state`, and only the app holds the PKCE verifier. The token exchange happens in the app, and tokens go into Halo's Credentials store.

The handler is stateless:
- It stores nothing and never sees tokens.
- It forwards only `code` and `state`, or a normalised `error`.
- It can check `state`'s shape but not its value. The app rejects any state it did not issue.
- Logging is off (`[observability] enabled = false`), so request URLs, which carry the code, are not recorded.

| File | Purpose |
|---|---|
| `callback.mjs` | The logic (~25 lines), shared by both hosts |
| `worker.mjs` + `wrangler.toml` | Cloudflare Worker (preferred, free plan) |
| `api/oauth/callback.mjs` + `vercel.json` | Vercel function (alternative, Hobby plan) |
| `test.mjs` | `node test.mjs`: dependency-free checks |

Deploy tools are run with `npx` and are not dependencies of Halo: `wrangler` for Cloudflare, `vercel` for Vercel.

## Deploy on Cloudflare (preferred)

1. **DNS.** Put your domain on Cloudflare (free plan), or use a domain already there.
2. **Deploy:**

   ```sh
   cd infra/oauth-callback
   node test.mjs
   npx wrangler login
   npx wrangler deploy
   ```

   The Worker is now live at `https://halo-oauth-callback.<your-account>.workers.dev/oauth/callback`. That address works for testing. Real providers should use your own domain.
3. **Custom domain.** In `wrangler.toml`, uncomment `routes` and set `pattern = "auth.<your domain>"`. Then run `npx wrangler deploy` again.
   - Cloudflare creates the `auth` DNS record (proxied, shown as type "Worker") and its TLS certificate automatically.
   - Manual setup has no separate A or CNAME to add: a custom domain must not have an existing record named `auth`.
4. **Check:**

   ```sh
   curl -sI "https://auth.<your domain>/oauth/callback?code=test&state=0123456789abcdef"
   ```

   It should return `302` with `location: halo://oauth/callback?state=0123456789abcdef&code=test`.

## Deploy on Vercel (alternative)

```sh
cd infra/oauth-callback
npx vercel deploy --prod
```

1. In the Vercel project, go to **Settings → Domains** and add `auth.<your domain>`.
2. At your DNS provider, create `CNAME auth → cname.vercel-dns.com` (Vercel shows the exact target).
3. In **Settings → Logs**, keep log drains off. Vercel's default runtime logs record request paths, including the query string, for a short time. That is one reason Cloudflare with observability off is preferred.

## Point Halo at it

Set the one value in `~/Library/Application Support/app.halo.native.dev/oauth.json`:

```json
{ "callbackURL": "https://auth.<your domain>/oauth/callback" }
```

In development, you can instead set `HALO_OAUTH_CALLBACK_URL=…` in the `.env` file. Until either is set, Halo falls back to a one-time `http://127.0.0.1:<port>` callback, so development keeps working.

Then paste the same URL into each provider that needs it (see `docs/OAUTH_SETUP.md`). Notion, Linear, Todoist and Stripe register it automatically.
