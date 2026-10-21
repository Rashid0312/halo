# Halo Roadmap

_Created 2026-10-21. The order of work across all Halo plans._

Detailed plans:

- [OpenClaw integration plan](OPENCLAW_INTEGRATION_PLAN.md) — Mac and browser automation (phases 0–7)
- [Local brain plan](LOCAL_BRAIN_PLAN.md) — Halo's own on-device model (phases L0–L6)

## Where things stand (2026-10-21)

| Track | Status |
| --- | --- |
| OpenClaw 0. Baseline | Almost done — app size and workflow latency not yet recorded |
| OpenClaw 1–4. Peekaboo, Mac reading, Mac actions, Chrome tabs | Complete |
| OpenClaw 5. Browser actions | In progress — click, type, select, scroll, navigate work on real sites; sensitive families, iframes, hostile-page tests remain |
| OpenClaw 6. Legacy automation retirement | Not started |
| OpenClaw 7. Release hardening | Not started |
| Local brain L0–L6 | L0 and L1 complete; recording is off until switched on in Settings |
| Electron app removal | Complete — moved to `../mercy-electron`; Swift build fetches its own dependencies |

## Order

| # | Step | Plan | Blocks |
| --- | --- | --- | --- |
| 1 | Commit pending browser and brain work | — | Done (`72c27c6`) |
| 2 | Move the Electron app out of this repo; Swift build fetches its own speech libraries and models | — | Done |
| 3 | Shared agent loop, tool-call validator, short scoped tool list | L0 | Done |
| 4 | Recorder, opt-in and scrubbed; start recording | L1 | Done — switch on in Settings → Privacy |
| 5 | Finish browser actions while examples accumulate; includes: `browser_app_id` needs a description (models guess "Safari"), and `open_in_browser` timed out loading Wikipedia | OpenClaw 5 | Tool freeze |
| 6 | Hostile-page (prompt-injection) tests | OpenClaw 5 | Local brain going live (L5) |
| 7 | Write the "normal work" task list, pick held-out websites, score ChatGPT baseline | L2 | Training |
| 8 | Freeze tool names and argument shapes; collect 1,000–3,000 examples | L3 | Training |
| 9 | Training rounds on Qwen3.5-4B until the pass mark | L4 | Local brain in Halo |
| 10 | Local brain inside Halo | L5 | Release |
| 11 | Retire legacy automation | OpenClaw 6 | Release |
| 12 | Release hardening, clean public model, first-launch download | OpenClaw 7 + L6 | — |

## Rules

- Recording starts as early as possible: collecting examples is the slowest part.
- A tool rename after step 8 needs a migration script for collected examples; an argument-shape change may mean discarding them.
- Approval gates never loosen for the local brain.
- Every step is verified in the running Halo app, not only with terminal checks.
