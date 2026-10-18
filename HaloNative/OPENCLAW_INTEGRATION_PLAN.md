# OpenClaw / Peekaboo Integration Plan

**Vendor revision**: Peekaboo v4.0.0 · commit ed3aaa4
**Last updated**: 2026-10-18
**Checkpoint**: c7165b4 (Verify Peekaboo capture approval flow)

## Invariants

- The legacy driver (`LegacyMacInteractionDriver`) is the default. Opt in with `HALO_MAC_DRIVER=peekaboo`.
- Halo's approval gate (show preview → user allow/deny) is never bypassed or delegated to Peekaboo.
- Peekaboo APIs are observation-only in Phases 1–2; mutations remain through Halo's existing UIAutomation layer.
- All Peekaboo calls run through the `MacInteractionDriver` boundary so the rest of Halo is driver-agnostic.

## Phase 1 — Capture & observation (COMPLETE as of c7165b4)

| Task | Status |
|------|--------|
| Vendor pinned Peekaboo source (v4.0.0 · ed3aaa4) | ✅ done |
| Define `MacInteractionDriver` protocol | ✅ done |
| `LegacyMacInteractionDriver` wraps UIAutomation + ScreenService | ✅ done |
| `PeekabooMacInteractionDriver` stubs wired into env-var opt-in | ✅ done |
| `inspect_ui` routed through driver | ✅ done |
| `inspect_screen` routed through driver | ✅ done |
| Peekaboo capture approval flow verified | ✅ done |

## Phase 2 — App/window listing via Peekaboo ApplicationService (IN PROGRESS)

| Task | Status |
|------|--------|
| Extend `MacInteractionDriver` with `runningApps()` and `listWindows(appID:)` | ✅ done |
| Implement both on `LegacyMacInteractionDriver` (NSWorkspace path preserved) | ✅ done |
| Implement both on `PeekabooMacInteractionDriver` (ApplicationService) | ✅ done |
| Route `running_apps` tool through driver | ✅ done |
| Route `list_apps` tool through driver (window counts) | ✅ done |
| Idle-resource timing: measure driver call latency in tool response | ✅ done |
| Check: `HaloCoreChecks` covers both drivers returning consistent fields | ⏳ next |

### Key decisions made in Phase 2

- `running_apps` now returns per-app `window_count` when the Peekaboo driver is active.  
  The legacy driver continues to return the flat list it already returned so no model-facing regression.
- `listWindows(appID:)` returns an array of window summaries (title, minimized, frontmost, screen).  
  This is observation-only; no mutation is dispatched without the approval gate.
- Latency field `driver_ms` is appended to `running_apps` JSON so idle-resource measurements are available to the model without a separate tool call.
- Peekaboo `ApplicationService` is initialized once per `PeekabooMacInteractionDriver` instance and reused.

## Phase 3 — Full mutation parity (PLANNED)

| Task | Status |
|------|--------|
| Route `ui_action` through Peekaboo driver | 📋 planned |
| Route `type_text` through Peekaboo driver | 📋 planned |
| Route `keypress` through Peekaboo driver | 📋 planned |
| Route `window_layout` through Peekaboo driver | 📋 planned |
| Cross-check approval flow coverage | 📋 planned |
| Remove legacy fallback for routed tools | 📋 planned |

## Phase 4 — Graduation & cleanup (PLANNED)

| Task | Status |
|------|--------|
| Make Peekaboo driver the default | 📋 planned |
| Deprecate `LegacyMacInteractionDriver` | 📋 planned |
| Remove env-var opt-in | 📋 planned |
| Update VERIFICATION.md | 📋 planned |
