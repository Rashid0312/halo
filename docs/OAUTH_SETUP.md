# OAuth setup: branded "Halo" sign-in for each provider

This guide makes each consent screen show **Halo** returning to an HTTPS address on our own domain. It covers the redirect address, the app name and logo, and Google's verification.

## The redirect: `https://auth.<your domain>/oauth/callback`

Providers return the user to Halo's hosted callback (`infra/oauth-callback`, a Cloudflare Worker). The Worker answers with a 302 to `halo://oauth/callback?code=…&state=…`, which the Mac app handles. In order:

1. The provider's consent page redirects to `https://auth.<domain>/oauth/callback`. This is the only redirect a provider ever sees.
2. The Worker (stateless) answers with a 302 to `halo://oauth/callback`, the last hop into the app.
3. Halo matches `state`, exchanges the code using its PKCE verifier, and saves the token in Credentials.

The `halo://` address is never registered with a provider, so providers have no custom-scheme redirect to warn about. Whether a provider still shows a note about the redirect domain is that provider's choice: an HTTPS address on your own verified domain is what avoids it. The browser still asks "Open Halo?" for the last hop. That prompt comes from the browser, appears on its own once the user ticks "Always allow", and is how every desktop app's browser sign-in returns.

**Until the callback is configured**, every provider falls back to a one-time `http://127.0.0.1:<port>/auth/callback`, so development keeps working. That loopback tab shows a Halo-branded "you can close this tab" page.

### Set it once

1. Deploy `infra/oauth-callback` and create the DNS record (see that folder's README).
   - **Cloudflare:** a Worker custom domain `auth.<domain>`. Cloudflare creates the DNS record and certificate.
   - **Vercel:** `CNAME auth → cname.vercel-dns.com`.
2. Set the single value in `~/Library/Application Support/app.halo.native.dev/oauth.json`:

   ```json
   { "callbackURL": "https://auth.<your domain>/oauth/callback" }
   ```

   In development you can instead set `HALO_OAUTH_CALLBACK_URL` in the `.env` file. Halo accepts only an `https://` URL with no query string.
3. Paste that exact URL into each provider that needs it:

| Provider | Who registers the OAuth app | Redirect URI to use | Notes |
|---|---|---|---|
| Notion | Halo, automatically | `https://auth.<domain>/oauth/callback`, registered automatically | Dynamic client registration. Tested 2026-10-23: accepts an HTTPS redirect on any domain. |
| Linear | Halo, automatically | same, registered automatically | Same test result. |
| Todoist | Halo, automatically | same, registered automatically | Same test result. |
| Stripe | Halo, automatically | same, registered automatically | Accepts HTTPS on any domain. It refused `halo://` (`invalid_redirect_uri`). |
| Slack | You, once (a Slack app named Halo) | **Paste** `https://auth.<domain>/oauth/callback` under OAuth & Permissions → Redirect URLs | See Slack below. |
| Google | You, once (Google Cloud OAuth client, type **Web application**) | **Paste** `https://auth.<domain>/oauth/callback` under Authorized redirect URIs | The domain must be an Authorized domain on the Branding page. See Google below. |

A Google **Desktop app** client cannot use an HTTPS redirect. If you keep one, add `"clients": { "google": { "clientId": "…", "loopback": true } }` to `oauth.json`, and Halo uses loopback for Google only.

## How the flow looks to the user

1. In Settings → Apps → Connected apps, the user clicks **Connect…**. A Halo card explains what Halo can do there, that changes always ask first, and which site sign-in will open.
2. **Continue in browser** opens the provider's own consent page. The card shows "Connecting to <App>…".
3. After the user approves, the browser hands off to Halo and Halo comes to the front. The card confirms "<App> is connected".

Security:
- PKCE (S256) and a random state protect every flow.
- The hosted callback forwards only `code` and `state`. It cannot use the code (no verifier), stores nothing, and has logging disabled.
- A `halo://` callback whose state no sign-in is waiting for is ignored. Any app can claim a custom scheme, but the code is worthless without the verifier that only Halo holds.

## Where configuration lives

- **Public branding and client IDs:** `~/Library/Application Support/<bundle id>/oauth.json` (development bundle id: `app.halo.native.dev`).

  ```json
  {
    "branding": {
      "name": "Halo",
      "homepage": "https://YOUR-DOMAIN",
      "logo": "https://YOUR-DOMAIN/halo-logo.png",
      "privacyPolicy": "https://YOUR-DOMAIN/privacy",
      "terms": "https://YOUR-DOMAIN/terms",
      "supportEmail": "support@YOUR-DOMAIN"
    },
    "clients": {
      "google": { "clientId": "1234-abc.apps.googleusercontent.com" },
      "slack":  { "clientId": "1234567890.1234567890" }
    }
  }
  ```

  Only `https://` branding URLs are sent. Halo has no public domain yet, so this file ships empty. Halo never makes up URLs.
- **Secrets** (client secrets and user tokens): only in Halo's Credentials store. That is a 0600 file in development builds and the Keychain in release builds.
  - Enter a client secret in Settings → Connected apps (OAuth client fields), or in development set `HALO_<APP>_CLIENT_SECRET` in the `.env` file.
  - Tokens and secrets are never logged.
- **Dynamic registrations:** Halo saves its registration for the hosted callback per provider (`connector.<id>.registration` in Credentials) and reuses it. The provider then lists one "Halo" app, not one per sign-in. Changing the branding in `oauth.json` registers a new one.

## You need first: a home for Halo's public pages

Google requires a domain you own, verified in Google Search Console, before it shows a name and logo on the consent screen. Slack and the services that register Halo automatically display these links too. Publish three pages on that domain:

- a homepage that describes Halo
- a privacy policy covering what Halo accesses, that data stays on the Mac except what is sent to the chosen model provider, and how to revoke access
- terms of service

Then put the URLs in `oauth.json`.

Logo: a square PNG. Google requires exactly 120×120 px and at most 1 MB. Slack's app icon is 512–2000 px square. Serve it over HTTPS from your domain.

---

## Notion, Linear, Todoist (automatic)

Nothing to register. Halo registers itself at the service's registration endpoint as a public client:

- `client_name` "Halo"
- `redirect_uris` set to the hosted callback (or to loopback until it is set)
- `client_uri`, `logo_uri`, `policy_uri`, `tos_uri` and `contacts` from `oauth.json`

Each service decides which of these it displays. All three accepted HTTPS redirects on any domain on 2026-10-23.

To revoke access, remove "Halo" from the service's connected-apps settings, or click **Disconnect** in Halo.

## Stripe (automatic)

Registration is automatic, as above, with the hosted HTTPS callback. Stripe's authorization server (`access.stripe.com/mcp`) rejects `halo://` but accepts HTTPS redirects. Use a test-mode account to keep it free.

## Slack (one-time app registration)

1. Go to <https://api.slack.com/apps> → **Create New App** → **From scratch**.
   - App Name: **Halo**.
   - Workspace: your own. Slack's MCP server accepts only internal or directory-published apps.
2. **Basic Information → Display Information**:
   - App icon: your Halo logo.
   - Short and long description.
   - Background color.
3. **OAuth & Permissions**:
   - **Redirect URLs**: add `https://auth.<domain>/oauth/callback`.
   - Turn on **PKCE**, since Halo always sends PKCE. This is one-way: it makes the app a public client. With PKCE, refresh tokens expire after 30 days and rotate; Halo refreshes them automatically.
   - **User Token Scopes**: `search:read.public`, `search:read.private`, `search:read.im`, `search:read.mpim`, `search:read.files`, `search:read.users`, `channels:history`, `groups:history`, `im:history`, `mpim:history`, `chat:write`, `canvases:read`, `canvases:write`, `users:read`, `users:read.email`. Add no bot scopes: Slack blocks bot scopes on desktop redirects.
4. **Install App** to your workspace. As its admin, approve it.
5. Copy the **Client ID** into Settings → Connected apps → Slack, or into `oauth.json` under `clients.slack`. With PKCE no client secret is needed; leave the secret empty.

## Google: Gmail, Calendar, Drive, Sheets (one-time project setup)

### 1. Project and APIs

1. Create a project at <https://console.cloud.google.com> named "Halo".
2. **APIs & Services → Library**: enable the Gmail API, Google Calendar API, Google Drive API and Google Sheets API.

### 2. Branding (Google Auth Platform → Branding)

These fields are what appears on the consent screen:

| Field | Value |
|---|---|
| App name | **Halo**. It must not imitate Google or another brand. |
| User support email | Your support address (shown to users) |
| App logo | 120×120 px square PNG/JPG, ≤ 1 MB. A logo puts the project into brand verification. |
| Application home page | `https://YOUR-DOMAIN` |
| Application privacy policy link | `https://YOUR-DOMAIN/privacy` |
| Application terms of service link | `https://YOUR-DOMAIN/terms` |
| Authorized domains | `YOUR-DOMAIN`, verified in Google Search Console by the project owner |
| Developer contact information | Your email (Google writes here about verification) |

Google may not show the name and logo until **brand verification** passes. That requires a verified domain, and the homepage and privacy policy hosted on it and linked from the homepage. Until then the screen can show the project's default name and an "unverified app" warning. Halo's Connect card says so for Google and never claims the app is verified.

### 3. Audience

- User type **External** for a personal @gmail.com account. Choose **Internal** if every user is in your Workspace organization. Internal skips verification and the user cap.
- Publishing status:
  - **Testing:**
    - Only listed test users (up to 100) can sign in, and they see an unverified-app warning.
    - **Authorizations and refresh tokens expire 7 days after consent** for apps requesting sensitive or restricted scopes. Gmail, Calendar, Drive and Sheets all are, so you would reconnect Google weekly.
  - **In production, unverified:**
    - Anyone can attempt sign-in, but users see "Google hasn't verified this app".
    - New users are capped at 100 over the project's lifetime.
    - Tokens do **not** expire after 7 days.
    - This is the practical choice for personal use. Google exempts personal-use apps, used only by you or a few people you know, from verification.

### 4. Client (Google Auth Platform → Clients → Create client)

1. Application type: **Web application**. Name: "Halo".
2. **Authorized redirect URIs**: paste `https://auth.<domain>/oauth/callback`. The domain must already be listed under Authorized domains on the Branding page.
3. Copy the Client ID into `oauth.json` (`clients.google.clientId`) or Settings. Put the client secret in Settings, or `HALO_GOOGLE_CLIENT_SECRET` in development. Google's token endpoint requires the secret. Halo also uses PKCE, and the secret is stored only in Credentials.

Before the domain exists, a **Desktop app** client works with loopback. Add `"loopback": true` to its `oauth.json` entry. Google discourages custom URI schemes for new clients, so Halo never registers `halo://` with Google.

### 5. Data access (scopes) and what verification each needs

Halo currently requests:

| Scope | Google class | Verification for public use |
|---|---|---|
| `openid`, `.../auth/userinfo.email` | non-sensitive | none |
| `.../auth/calendar` | sensitive | sensitive-scope verification |
| `.../auth/spreadsheets` | sensitive | sensitive-scope verification |
| `.../auth/gmail.modify` | **restricted** | restricted-scope verification **plus security assessment** |
| `.../auth/drive` | **restricted** | restricted-scope verification **plus security assessment** |

- **Sensitive-scope verification** (no fee):
  - brand verification done
  - a justification for each scope
  - a demo video of the consent flow and of how each scope is used
  - Google's review
- **Restricted-scope verification:**
  - Everything above, plus compliance with the Google API Services User Data Policy's Limited Use rules.
  - A **CASA security assessment** by a Google-empanelled assessor whenever restricted data can be accessed from or through a third-party server.
  - Halo sends tool results to the cloud model (DeepSeek). Treat that as requiring the assessment unless the privacy gate keeps Gmail and Drive content local.
  - The assessment repeats at least every 12 months.
  - Assessors set their own fees, so this route is **not free**. It conflicts with Halo's $0 rule, so for now Google stays on the personal-use route.

Ways to reduce what needs verification:
- Use `drive.file` (non-sensitive: only files the user opens or creates with Halo) instead of `drive`.
- Use `gmail.send` (sensitive) or `gmail.readonly` (restricted) instead of `gmail.modify`, depending on what Halo must do.
- Use `calendar.events` instead of `calendar`.

To narrow scopes, edit the Google entry in `ConnectorSpec.catalog` and check that workspace-mcp's tools still work with them.

Until verification: keep the project **In production, unverified** with yourself as the only user, or in **Testing** with yourself as a test user (weekly reconnect).

---

## Checks

- `node infra/oauth-callback/test.mjs`: the hosted callback forwards only code and state (or an error) and rejects malformed requests.
- `build/Halo.app/Contents/MacOS/Halo --check-oauth-callback`: macOS delivers `halo://oauth/callback` to Halo, and only the waiting sign-in with the matching state receives it.
- `build/Halo.app/Contents/MacOS/Halo --connect-connector notion --tool notion-search --arguments '{"query":"project"}'`: a real sign-in (hosted callback when configured, else loopback), then one read-only call.
