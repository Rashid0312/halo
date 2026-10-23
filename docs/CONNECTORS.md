# Connectors

Halo connects to apps through three free routes. It does not use a paid aggregator (Pipedream, Composio, Arcade, or similar). Every app either has a $0 route or is marked **deferred**.

- **(a) Official hosted MCP.** The app runs its own remote MCP server. Halo signs in with OAuth 2.1 + PKCE. The provider returns to Halo's hosted HTTPS callback, which falls back to a 127.0.0.1 callback until it is configured (see OAUTH_SETUP.md).
- **(b) Self-hosted MCP.** An open-source server runs on this Mac. You register your own OAuth app or token with the service.
- **(c) Direct API.** Halo calls the app's REST API with your token.

Availability was checked on 2026-10-23 by fetching each hosted server's live OAuth metadata (`/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server`). The vendors' own docs were used where metadata could not settle a question.

| # | App | Route | Auth | Server / endpoint | Notes |
|---|-----|-------|------|-------------------|-------|
| 1 | Gmail | (b) self-host | Your Google Cloud OAuth client (free; Web application with the hosted callback, or Desktop with loopback). Halo keeps the tokens in Credentials and sends the access token as a bearer on each request. | `uvx workspace-mcp==2.1.2 --transport streamable-http --tools gmail calendar drive sheets` on 127.0.0.1 ([taylorwilsdon/google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp), MIT) | Google's official servers (`gmailmcp.googleapis.com/mcp/v1` etc.) are in **Developer Preview**, gated by program membership. Switch to them when they open. Runs with `EXTERNAL_OAUTH21_PROVIDER=true` and `WORKSPACE_MCP_STATELESS_MODE=true`, so the server never writes tokens to disk. One process serves rows 1, 2, 3 and 14. |
| 2 | Google Calendar | (b) self-host | same as Gmail | same process | Tools are named `calendar__…` |
| 3 | Google Drive | (b) self-host | same as Gmail | same process | Tools are named `drive__…` |
| 4 | Slack | (a) official hosted | Your own **internal** Slack app (client id + secret; free). Slack has no dynamic registration. | `https://mcp.slack.com/mcp` | Slack allows only internal or directory-published apps to use MCP. Register the redirect `https://auth.<domain>/oauth/callback` (see OAUTH_SETUP.md). A workspace admin must approve the app, and that is you on your own workspace. |
| 5 | Notion | (a) official hosted | OAuth with dynamic client registration (no app to register) | `https://mcp.notion.com/mcp` | Notion's self-hosted server is no longer maintained, so the hosted one is used. |
| 6 | Discord | (c) direct API | Bot token from your own Discord application | `https://discord.com/api/v10` | There is no official MCP server. Community servers that log in as you break Discord's terms, so Halo acts only as your bot: it lists servers and channels, reads messages, and sends messages. Mentions are disabled. |
| 7 | Telegram | (c) direct API | Bot token from @BotFather | `https://api.telegram.org/bot<token>/` | There is no official MCP server. The bot can see only chats that messaged it or added it. Tools: get_me, get_updates (reading never confirms updates), and send_message. |
| 8 | WhatsApp | **deferred** | — | — | The Cloud API needs a Meta business account and charges per message for business-initiated conversations. Personal-account bridges such as whatsmeow break WhatsApp's terms. The existing browser path stays. |
| 9 | GitHub | (b) self-host | Fine-grained personal access token, passed only in the server's environment | `github-mcp-server stdio` [v2.0.3](https://github.com/github/github-mcp-server) (official, open source) | GitHub also hosts `api.githubcopilot.com/mcp`, but it has no dynamic registration and may require Copilot. The local official binary is free and private. Install with `go install github.com/github/github-mcp-server/v2/cmd/github-mcp-server@v2.0.3`. Toolsets: context, repos, issues, pull_requests, notifications. |
| 10 | Linear | (a) official hosted | OAuth with dynamic client registration | `https://mcp.linear.app/mcp` | — |
| 11 | Stripe | (a) official hosted | OAuth with dynamic client registration (authorization server: `access.stripe.com/mcp`) | `https://mcp.stripe.com` | Using a test-mode account costs nothing. Every write (charges, refunds, invoices) asks for approval. |
| 12 | Spotify | **deferred** | — | — | Since February 2026, the owner of a development-mode Web API app must have Spotify **Premium**, which is paid. Playback control already works through `browser_media`. |
| 13 | Todoist | (a) official hosted | OAuth with dynamic client registration (authorization server: `todoist.com`) | `https://ai.todoist.net/mcp` | — |
| 14 | Google Sheets | (b) self-host | same as Gmail | same process as Gmail | Tools are named `sheets__…` |

## How tools reach the model

- Tools are named `app__tool`, for example `notion__notion-search`, `gmail__send_gmail_message` and `telegram__send_message`. Halo's own tools (`list_browser_tabs`, `type_text`, `run_shell`…) are unchanged and never shadowed.
- A connected app's tools are added only to requests that mention the app, such as "notion", "email", "calendar" or "repo". When a request mentions no connected app, the tool list is byte-identical to the built-in one.
- A tool counts as a write if the server does not mark it read-only, or if its name contains a write verb (send, post, create, pay, delete…). Every write waits for approval, with no "don't ask again" option.
- Results are capped at 32 KB and marked as untrusted data.
- Halo refuses any connector call that targets LinkedIn.

## Privacy scrub

You can turn this on in Settings → Mac Access → Connected-app privacy.

- Connector results reach the model with emails, phone numbers, card numbers and keys replaced by stable labels such as `[EMAIL_1]`.
- When the model uses a label in a tool argument, Halo swaps the real value back on this Mac just before the API call. The approval preview also shows real values.
- Halo refuses a label it never issued, so a guessed placeholder is never sent as data.

## Setting up (development)

Add tokens and OAuth clients in Settings → Apps → Connected apps. Development builds can also read these from the `.env` file:

```
HALO_GITHUB_TOKEN=github_pat_…
HALO_TELEGRAM_TOKEN=123456:ABC…
HALO_DISCORD_TOKEN=…
HALO_GOOGLE_CLIENT_ID=….apps.googleusercontent.com
HALO_GOOGLE_CLIENT_SECRET=…
HALO_SLACK_CLIENT_ID=…
HALO_SLACK_CLIENT_SECRET=…
HALO_OAUTH_CALLBACK_URL=https://auth.<domain>/oauth/callback
```

Local servers need `uv` (for Google) and the `github-mcp-server` binary (for GitHub). Halo starts them on first use and stops them when it quits.

## Cost

There is no recurring cost. Every route uses the user's own free account, token, or OAuth app.
