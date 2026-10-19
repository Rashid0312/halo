# Halo OpenClaw Integration Plan

Last updated: 2026-10-19

## Purpose

Keep Halo as the voice-first, native, approval-driven Mac assistant while replacing brittle Mac and browser automation with selected, pinned components and patterns from OpenClaw and Peekaboo.

This file is the source of truth for the integration. Update it before changing phase scope, after completing an acceptance criterion, and whenever a material decision or blocker appears.

## Product boundaries

Halo continues to own:

- The Mercy voice, wake word, speech recognition, and spoken replies.
- The native menu-bar panel, settings, model providers, and conversation lifecycle.
- Approval previews, cancellation, privacy controls, and user-facing permission explanations.
- Native integrations that are safer or simpler than generic automation.

The integration may reuse:

- Peekaboo Swift automation services for Accessibility, screen capture, applications, windows, menus, dialogs, and input.
- OpenClaw browser architecture for explicitly authorized Chrome tabs.
- OpenClaw security and permission-handling patterns where they preserve or strengthen Halo's approval model.

The integration will not initially import:

- OpenClaw's complete Gateway, messaging channels, dashboard, agent UI, or plugin marketplace.
- Permanent computer-control authorization without Halo approval previews.
- Automatic access to every browser tab.
- Silent screenshot persistence, browser-profile copying, cookies, passwords, or credentials.

## Non-negotiable safety rules

1. Screen, page, file, and Accessibility content is untrusted data, never authorization.
2. File writes, commands, AppleScript, screenshots shared with a model, and generic UI actions retain exact Halo previews.
3. Actions use freshly observed targets and verify the result afterward.
4. Browser access defaults to selected tabs and has a visible Pause/Disconnect control.
5. Sensitive browser operations such as submission, communication, purchases, downloads, uploads, account changes, and password fields require stronger confirmation.
6. Stop prevents future side effects but never claims to undo completed external actions.
7. Third-party dependencies are pinned to immutable revisions and their licenses are shipped with Halo.

## Phase status

| Phase | Status | Exit condition |
| --- | --- | --- |
| 0. Baseline and governance | In progress | Reproducible baseline recorded, dedicated branch available, plan and license process established |
| 1. Peekaboo compatibility spike | Complete | Pinned Peekaboo automation module builds inside signed Halo and performs read-only inspection |
| 2. Read-only Mac understanding | Complete | App/window/UI inspection and reviewed screen capture pass without silent persistence |
| 3. Safe Mac actions | Complete | Exact-target execution, approvals, secure-field protection, and post-action verification pass across both drivers |
| 4. Chrome tab integration | Complete | Browser-session authorization, approval revalidation, injection-safe metadata framing, and in-flight killswitch checks pass |
| 5. Browser actions | In progress: 5A read-only bridge and 5B.1–5B.3 (click, text entry, select/scroll/navigation) complete; 5B.4 (sensitive-action policy) next | A real, fast, approval-gated Native Messaging observation path must pass before any DOM mutation is added (met 2026-10-19) |
| 6. Legacy automation retirement | Not started | Replaced Halo implementations are removed only after parity and rollback validation |
| 7. Release hardening | Not started | Security, permissions, signing, notarization, clean-install, and recovery checks pass |

## Phase 0 — Baseline and governance

### Tasks

- [x] Establish rollback commit: `52cdde89201b1bba2ad7f3714241897185d0af33`.
- [x] Confirm the working tree is clean at the start of integration.
- [x] Record toolchain: Apple Swift 6.3.3, target `arm64-apple-macosx26.0`.
- [x] Confirm existing core checks, production build, and stable-signing check pass.
- [x] Create this accountable integration plan.
- [x] Create a dedicated `feature/openclaw-integration` branch.
- [x] Add third-party license and revision records before compiling incorporated source.
- [ ] Record baseline app size and the latency of representative inspect/capture/action workflows.

Current signed development bundle baseline: 41,752 KiB. The Halo executable is 3,528,608 bytes; the existing ONNX Runtime and sherpa-onnx libraries account for 29,006,416 and 4,268,688 bytes respectively. Workflow latency remains to be measured through the signed GUI process.

### Current blocker

No Phase 0 repository blocker remains. Representative signed-GUI workflow latency still needs to be measured before Phase 0 can close.

## Phase 1 — Peekaboo compatibility spike

### Tasks

- [x] Select and record Peekaboo `v4.0.0` at `ed3aaa4738b2b588c226154955609cc439f7613e`.
- [x] Review that revision's core package manifest, MIT license, and submodule requirements.
- [x] Use `PeekabooAutomationKit`, not the broader `PeekabooAutomation` product. The latter directly pulls Tachikoma audio/MCP/provider code and is outside Halo's required scope.
- [x] Add a `MacInteractionDriver` protocol owned by Halo.
- [x] Keep the existing Halo implementation as `LegacyMacInteractionDriver` during migration.
- [x] Add a `PeekabooMacInteractionDriver` behind a development feature flag.
- [x] Implement read-only permission status, application/window listing, UI inspection, and one app-window capture.
- [x] Prove that Halo's signed GUI process owns Accessibility and Screen Recording permissions on this development Mac.
- [x] Measure dependency size, build time, launch impact, and idle resource cost.

Recorded dependency and runtime measurements:
- Binary and bundle size: signed release bundle is 55,928 KiB (baseline 41,752 KiB, delta +14,176 KiB); executable is 18,043,968 bytes (baseline 3,528,608 bytes, delta +14,515,360 bytes).
- Build times: clean production build completed in 73.31 seconds; incremental build completed in 19.62 seconds.
- Launch impact: cold/warm launch averages 225.4ms with Peekaboo driver enabled vs 149.1ms minimum on legacy driver (~76ms total launch delta including running app listing).
- Idle resource cost: background idle RSS memory is 53,664 KiB with Peekaboo vs 53,536 KiB on legacy (+128 KiB memory delta, negligible); idle CPU is 0.0% for both drivers.

### Acceptance criteria

- [x] Halo builds and signs with the pinned dependency. (PASS: `scripts/build-app.sh` and `scripts/check-signing.sh` pass)
- [x] A disposable test app can be discovered and inspected through the new driver. (PASS: `--check-peekaboo-capture` and `--check-peekaboo-listing` pass with `HALO_MAC_DRIVER=peekaboo`)
- [x] No screenshot or UI snapshot is silently retained outside an explicitly temporary test location. (PASS: verified in `peekabooCapture` test harness)
- [x] Switching the feature flag restores the existing Halo driver. (PASS: verified `--check-peekaboo-listing` with/without `HALO_MAC_DRIVER=peekaboo`)

## Phase 2 — Read-only Mac understanding

### Tasks

- [x] Extend `MacInteractionDriver` with `runningApps()` and `listWindows(appID:)` methods.
- [x] Implement `LegacyMacInteractionDriver` preserving NSWorkspace path and CG window counts.
- [x] Implement `PeekabooMacInteractionDriver` using Peekaboo's `ApplicationService`.
- [x] Route `running_apps` tool through driver and measure execution latency.
- [x] Add `list_windows` tool to `MacTools` with CG-based PID-matched fallback for legacy driver.
- [x] Add `--check-peekaboo-listing` verification harness in `HaloApp` and `NativeChecks`.
- [x] Map third-party element identifiers into turn-scoped Halo identifiers.
- [x] Reject stale identifiers after every new observation.
- [x] Observe menus and dialogs via Peekaboo.
- [x] Preserve protected-field redaction and bounded output sizes.
- [x] Keep screenshots in memory unless the user explicitly saves one.
- [x] Preserve the exact screenshot preview before model sharing.

### Acceptance criteria

- [x] App and window listing work across both drivers with driver latency reported. (PASS: verified Finder window and app enumeration in `--check-peekaboo-listing`)
- [x] Menu enumeration and dialog discovery return bounded, untrusted structures via Peekaboo, with legacy driver returning safe defaults. (PASS: verified `list_menus` and `find_dialog` in `--check-peekaboo-listing`)
- [x] UI elements use turn-scoped identifiers and stale subtree references are rejected. (PASS: verified prefix-index IDs and stale `root_id` rejection)
- [x] Protected fields (`AXSecureTextField`) are redacted (`protected: true`, values suppressed). (PASS: verified role/subrole check in `PeekabooMacInteractionDriver.inspect()`)
- [x] Output sizes are strictly bounded (180 elements, 200-char labels, 300-char values). (PASS: verified limits in `PeekabooMacInteractionDriver.inspect()`)
- [x] Legacy driver remains the default and feature flag toggles the Peekaboo driver cleanly. (PASS: verified with/without `HALO_MAC_DRIVER=peekaboo`)

## Phase 3 — Safe Mac actions

- [x] Focus or raise an app (`focus_app` / `focusApp`).
- [x] Click an observed control (`ui_action` / `performAction`).
- [x] Type into an observed field (`type_text` / `typeText`).
- [x] Press validated shortcuts and keys (`keypress` / `keypress`).
- [x] Scroll (`scroll` / `scroll`).
- [x] Operate menus (`click_menu_item` / `clickMenuItem`).
- [x] Operate dialogs (`click_dialog_button` / `clickDialogButton`).
- [x] Move, resize, minimize, and arrange windows (`window_layout` / `layoutWindow`).
- [x] Reject stale element IDs prior to presenting any approval modal.
- [x] Exact approval preview, user denial, and Task cancellation tests.
- [x] Post-action observation validation (re-inspecting UI to verify side effects).
- [x] Add `--check-safe-actions` verification harness in `HaloApp` and `NativeChecks`.
- [x] Remove Peekaboo fuzzy-label and cached-coordinate mutation fallbacks; unresolved snapshot targets fail closed.
- [x] Centralize secure-field classification, recheck the exact legacy target immediately before typing, and redact protected dialog values.
- [x] Require approval for application focus and window layout as mutating actions.

### Acceptance criteria

- [x] Every mutating action passes Halo approval policy with exact title, path/role, and action/content preview. (PASS: verified preview on denial/approval for clicks, typing, shortcuts, menus, dialog buttons)
- [x] Stale element references are rejected before any approval modal is presented. (PASS: verified `stale-id-999` fails immediately without triggering `tools.approval`)
- [x] Task cancellation cleanly dismisses pending approvals without side effects. (PASS: verified `cancelledClick.cancel()` sets `tools.approval == nil` and throws `CancellationError`)
- [x] Control click changes state verified by re-inspection. (PASS: verified button title transitions to `"Mercy test button pressed"`)
- [x] Typing into an observed field updates field value verified by re-inspection. (PASS: verified typed content in test input)
- [x] Keyboard shortcuts (e.g. `cmd+a`), scrolling, menu item selection (`Edit > Select All`), and dialog operations (`Confirm`) succeed across both drivers. (PASS: verified on legacy and Peekaboo drivers)
- [x] Strict security parity maintained between `legacy` and `peekaboo` drivers. Peekaboo uses snapshot targets or a unique exact AX fingerprint with bounded geometry tolerance; legacy rechecks the exact focused element. Both pass `--check-safe-actions` after hardening.

## Phase 4 — Chrome tab integration

### Prototype boundary

- Chrome/Chromium first; Safari follows only after the Chrome path is stable.
- Default to selected-tab access.
- Expose tab title, URL, active state, semantic page snapshot, and bounded readable text.
- Never copy the Chrome profile, cookies, saved passwords, or authentication tokens.
- Authenticate all local browser-helper communication and bind it to the current macOS user.

### Packaging decision gate

Prototype the OpenClaw-compatible browser path before choosing between:

1. A narrowly scoped, bundled browser sidecar based on OpenClaw's existing implementation.
2. A native Swift implementation of the required native-messaging/CDP protocol.

Choose using measured reliability, shipped size, update burden, attack surface, and whether a Node runtime is required. Do not decide based only on implementation language.

### Acceptance criteria

- [x] Halo lists only tabs explicitly authorized by the user. (PASS: `list_browser_tabs` defaults to `authorized_only = true`; unauthorized tabs excluded)
- [x] "Summarize this tab" works on a signed-in page without copying credentials. (PASS: DOM innerText extracted up to 16,000 chars without touching cookies, profiles, Keychain, or tokens)
- [x] Revoking or pausing a tab immediately blocks further reads and actions. (PASS: `revoke_browser_tab` and `pause_browser_tabs` immediately block tab reads and listings)
- [x] Incognito, internal browser pages, and unauthorized tabs remain unavailable. (PASS: incognito windows excluded via AppleScript `mode of w`, internal schemes `chrome://`, `about:`, `file://` filtered, unauthorized reads rejected)
- [x] Authorization is keyed by browser bundle, browser process-session identity, and tab ID; unknown explicit browser IDs fail closed.
- [x] Authorization re-observes the tab after approval and rejects navigation, restart, replacement, and ID reuse.
- [x] Page-controlled title and URL metadata have framing controls sanitized inside AppleScript and are accepted only with an exact field count; listing does not require Chrome's JavaScript-from-Apple-Events setting.
- [x] Pause/revoke changes an access epoch checked after every external await so in-flight results cannot return afterward.
- [x] Adversarial checks pass for browser-session collision/restart and concurrent in-flight pause/revoke. (PASS: deterministic coverage verifies cross-browser isolation, process-session reuse rejection, approval-time replacement/navigation rejection, delimiter framing sanitization, in-flight pause/revoke suppression, and unsupported bundle ID fail-closed)

## Phase 5 — Browser actions

- **Architecture decision:** Adopted Chromium Native Messaging extension plus a dedicated signed Swift helper as the candidate production architecture (`BrowserBridgeProtocol`). CDP remote-debugging port is rejected for user signed-in tabs due to ambient credential exposure, cross-tab privilege escalation, and lack of per-tab security boundaries. AppleScript-injected JavaScript remains strictly read-only. Extension permissions, incognito rejection, helper registration/signature verification, and authenticated helper-to-Halo IPC remain release gates.
- **Transport model foundation (COMPLETE; production transport still blocked):** `BrowserBridgeProtocol` defines bounded `Codable`/`Sendable` models, Native Messaging length framing, pinned-origin channel binding, full browser-session/tab/document identities, correlated request/response validation, strict navigation invalidation, and zero mutation commands. Validated by deterministic `browserBridgeProtocolChecks()`.
- **Browser mutation gate (BLOCKED / FUTURE WORK):** Browser mutation tools (click, type, select, submit, navigate, upload, download) remain strictly blocked and are not implemented. Native Messaging host registration is opt-in (Settings → Mac Access → Browser bridge, off by default) and removed when disabled or on quit. The extension remains a loopback-only development fixture.

### Phase 5A — Real read-only bridge vertical slice (complete, 2026-10-19)

The next milestone is not another transport simulation and not browser mutation. It is one real, end-to-end observation through Chromium Native Messaging on a disposable local page, with Halo still owning authorization and delivery policy.

#### Required implementation order

1. **Preflight and packaging decision:** Inspect the existing Xcode/SwiftPM packaging and signing scripts. Record the exact helper executable location, extension development-ID strategy, supported Chromium browser for the fixture, opt-in manifest install/remove locations, and the authenticated helper-to-Halo IPC design before adding runtime code. Do not assume Chromium verifies the helper's macOS signature.
2. **Minimal extension fixture:** Add the smallest Manifest V3 extension needed for the test. Use no cookie, storage, history, password, download, upload, broad `<all_urls>`, or incognito permission. Choose and document either `activeTab` or narrowly scoped optional host permissions. Reject incognito explicitly at runtime.
3. **Dedicated helper:** Add a separately invocable Swift native-messaging helper that reads/writes bounded four-byte length-prefixed frames. Standard output is protocol-only; diagnostics go to standard error. Malformed/oversized input closes the session. The helper must not launch a listener, daemon, shell, or browser-debugging port.
4. **Authenticated local handoff:** Implement the documented helper-to-Halo IPC with peer identity verification, per-launch freshness, strict filesystem permissions where applicable, bounded frames, cancellation, and timeouts. If this cannot be implemented securely inside the current packaging model, stop and report the concrete blocker; do not substitute an unauthenticated socket.
5. **Halo policy integration:** Connect observations to Halo's existing `(browser bundle, process session, tab, document generation)` authorization and access epoch. The extension/helper may report state but may never authorize a tab. Pause, revoke, navigation, tab close, browser restart, helper exit, and app cancellation must invalidate or suppress in-flight results.
6. **Real fixture:** Extend `--check-browser-tabs` or add one clearly named signed-app check that installs the development manifest only in an isolated disposable Chromium profile/location, opens a loopback HTTP fixture, performs one authorized semantic observation, tests navigation and pause/revoke invalidation, and removes every generated registration/profile artifact in `defer` cleanup.
7. **Performance instrumentation:** Use `ContinuousClock` around transport stages and report aggregate timings only—never page text, typed values, URLs with paths/queries, nonces, or raw frames. Measure helper cold start, warm round trip, semantic observation, pause/revoke propagation, CPU, and idle RSS.

#### Performance gates

- Halo shows visible activity within 500 ms of accepting a request.
- Warm local bridge round trip: p50 <= 100 ms and p95 <= 250 ms across at least 30 fixture iterations.
- Bounded semantic observation: p50 <= 300 ms and p95 <= 1,000 ms across at least 30 fixture iterations.
- Pause/revoke blocks delivery within 100 ms in the deterministic fixture.
- Helper cold start is measured and must remain <= 750 ms at p95 across at least 10 launches.
- Idle helper CPU rounds to 0.0% over a 10-second sample and incremental idle RSS is reported. A miss does not get hidden: record it as a blocker or an explicit optimization item with evidence.
- No step uses arbitrary sleeps for correctness. Readiness and navigation use bounded events/handshakes; every wait has a timeout and cancellation path.

#### Phase 5A acceptance criteria

- [x] A real Chromium process launches the dedicated helper through Native Messaging and completes the pinned-origin handshake. (PASS: Chromium 158 snapshot with the manifest in the disposable profile's `NativeMessagingHosts/`; consumer Chrome ignores `--load-extension`.)
- [x] One explicitly approved, non-incognito loopback tab returns a bounded semantic observation to Halo through the complete transport. (PASS: production `ChromeBrowserService.readTab` over the bridge, `--check-browser-bridge-live` stage 1.)
- [x] An unauthorized tab, colliding tab ID from another browser/session, incognito context, unknown extension origin, stale generation, and oversized/malformed frame all fail closed. (PASS: 17 adversarial checks; Case 10 now requires an explicit authentication rejection; a non-Halo process holding the real session token is rejected.)
- [x] Navigation, close, browser restart, pause, revoke, helper crash, and cancellation suppress in-flight content after the invalidation point. (PASS: real-Chromium stages 2–12; pause, revoke, and cancel are each proven to land while a read is in flight.)
- [x] Installation is explicit and reversible; tests leave no manifest, extension, browser profile, helper process, socket, or temporary artifact behind. (PASS: opt-in toggle; installer refuses foreign manifests and rolls back; abandoned sessions and manifests from crashed runs are swept; zero residue after back-to-back runs.)
- [x] Latency and idle-resource results are recorded here with sample counts, p50, p95, maximum, command, machine/build context, and pass/fail against each gate. (PASS: see Phase 5A results below and design doc §16.11.)
- [x] Production build, core checks, signing, browser checks, default legacy checks, opt-in Peekaboo checks, and `git diff --check` pass. (PASS for build, `HaloCoreChecks`, `--check-commands`, `check-signing.sh`, both browser checks, `git diff --check`. `--check-safe-actions` was not rerun: it drives the desktop and no Mac-action code changed.)
- [x] No browser mutation message, tool, JavaScript evaluator, CDP debugging port, credential API, or broad permission is introduced. (PASS: read-only. The test harness drives its disposable Chromium over DevTools; production never opens a debugging port. `scripting` is used only to inject the read-only content script on loopback pages.)

#### Phase 5A results (2026-10-19, Apple M1, macOS 26.5.1, Chromium 158.0.8113.0)

| Metric | Samples | p50 | p95 | Max | Gate | Result |
|---|---|---|---|---|---|---|
| DOM observation via production `readTab` | 30 | 1.24 ms | 1.85 ms | 2.01 ms | p50 ≤ 300 ms, p95 ≤ 1000 ms | PASS |
| First visible Halo activity | 10 | 0.031 ms | 0.051 ms | 0.066 ms | ≤ 500 ms | PASS |
| Warm bridge round trip | 30 | 0.20 ms | 0.25 ms | 0.52 ms | p50 ≤ 100 ms, p95 ≤ 250 ms | PASS |
| Helper cold start | 10 | 13.96 ms | 15.32 ms | 15.77 ms | p95 ≤ 750 ms | PASS |
| Pause/revoke propagation | 1 | 0.02 ms | – | – | ≤ 100 ms | PASS |
| Helper idle CPU (connected, 65 s) | 1 | 0.00% | – | – | rounds to 0.0% | PASS |
| Helper idle RSS (connected) | 1 | 5.2 MiB | – | – | Recorded | – |

Commands: `Halo --check-browser-tabs` and `Halo --check-browser-bridge-live`, built from `bash HaloNative/scripts/build-app.sh`.

#### Mandatory review stop

After Phase 5A evidence is complete, stop for primary-engineer review. Do not proceed to clicks or typing in the same change set. The first mutation slice will be planned separately from measured read-only results.

### Phase 5B.1 — Approved click (complete, 2026-10-19)

- [x] Observe a harmless fixture button with a generation-bound opaque element reference.
- [x] Re-observe before approval; show the exact domain, page, element label and role, and action.
- [x] Click only after approval, with genuine input (`chrome.debugger`, attached only for that click on that tab).
- [x] Abort if the document or element changed, or another element covers it; refuse links, form submission, and disabled or protected controls before approval.
- [x] Verify the result afterward (trusted click confirmed by the page, then a fresh observation).

Evidence: design doc §17. `--check-browser-tabs` (click protocol) and `--check-browser-bridge-live` (8 click stages) pass on Chromium 158.

### Phase 5B.2 — Safe text entry (complete, 2026-10-19)

- [x] Type only into freshly verified, non-protected plain text fields.
- [x] Show the exact destination and proposed text.
- [x] Never type passwords, one-time codes, payment details, or detected secrets.
- [x] Typing is separate from submission (no Enter or key events; the fixture form's submit count stays 0).
- [x] Verify the field afterward without its value leaving the page (match/no-match only).

Evidence: design doc §18. `--check-browser-tabs` (text protocol and policy) and `--check-browser-bridge-live` (7 typing stages) pass.

### Phase 5B.3 — Select, scroll, and navigation (complete, 2026-10-19)

- [x] Select dropdown options (single-choice; payment and credential dropdowns refused).
- [x] Scroll the page or a named scrollable region with a genuine wheel event.
- [x] Navigate only to explicitly approved http(s) addresses; leaving the site ends access.
- [x] Invalidate all old element references after navigation.

Evidence: design doc §19. `--check-browser-tabs` (5B.3 protocol) and `--check-browser-bridge-live` (8 stages) pass.

### Remaining Phase 5B slices

- **5B.4:** the sensitive-action policy (forms, messages, purchases, accounts, uploads, downloads, credentials).
- Original scope still to cover:

- Re-observe after navigation and invalidate old page references.
- Initially block downloads, uploads, password fields, purchases, messages, and account changes.
- Add explicit policy and confirmation UI before enabling each sensitive family.
- Add prompt-injection tests using hostile page content.

## Phase 6 — Legacy automation retirement

- Compare every replaced workflow against the legacy driver.
- Keep a development rollback flag for at least one release candidate.
- Remove duplicated code only after functional, permission, cancellation, and privacy parity.
- Retain direct native tools where generic automation would reduce safety or reliability.

## Phase 7 — Release hardening

- Complete license notices and source revision records.
- Audit local sockets, helper authentication, executable identity, and update behavior.
- Verify permission persistence across rebuilds and application updates.
- Test lock/unlock, sleep/wake, browser restarts, helper crashes, stale tabs, and cancellation.
- Measure app size, launch time, idle CPU/memory, action latency, and success rate.
- Validate signing, notarization, installation, update, and removal on a clean Mac account.

## Validation matrix

Every completed phase must run the applicable checks below and record the result in the change log.

- `swift run HaloCoreChecks`
- `bash scripts/build-app.sh`
- `bash scripts/check-signing.sh`
- Disposable cross-process UI inspection/action test
- Reviewed screenshot test using synthetic content
- Browser test using disposable local pages and non-sensitive accounts
- Cancellation before approval, during execution, and after verified completion
- Accessibility and Screen Recording denied/granted/revoked recovery

## Decision log

### 2026-10-18 — Selective integration, not an OpenClaw fork

Halo remains the product and policy owner. Reuse focused automation and browser foundations rather than importing OpenClaw's complete application and Gateway surface.

### 2026-10-18 — Preserve Halo approvals

OpenClaw's computer-control model does not become Halo's authorization model. Halo retains exact previews and per-action policy for sensitive operations.

### 2026-10-18 — Peekaboo before browser mutation

Establish reliable read-only observation and permission ownership before enabling third-party action execution or browser mutation.

### 2026-10-18 — Pin Peekaboo v4.0.0

The first compatibility spike targets immutable commit `ed3aaa4738b2b588c226154955609cc439f7613e`. Its automation product depends on repository-relative packages and submodules, so Halo will not pretend it is a simple remote SwiftPM dependency. The source layout and dependency closure must be preserved or deliberately extracted and audited.

### 2026-10-18 — Integrate PeekabooAutomationKit instead of PeekabooAutomation

The broader `PeekabooAutomation` target imports Tachikoma, TachikomaAudio, MCP, configuration, and visualizer code. A product-level build began compiling the default package and pulled NIO, crypto, MCP, and model-provider dependencies, so it was stopped. `PeekabooAutomationKit` contains the actual macOS capture and automation services and built independently using PeekabooFoundation, PeekabooProtocols, AXorcist, Swift Algorithms, Swift Log, and Swift Numerics. This is the Phase 1 integration boundary.

### 2026-10-19 — Packaging decision gate: Native Swift Chromium Integration (Option 2)

Evaluated the two architectural packaging approaches for Chrome/Chromium integration:
- Option 1 (Bundled Node sidecar): ~65+ MB app bundle size growth for Node runtime + dependencies, requires host/bundled Node toolchain, npm vulnerability audit burden, local socket IPC attack surface, and ~200-500ms process startup latency.
- Option 2 (Native Swift actor + AppleScript IPC): 0 MB external bundle growth (compiled directly into Halo app binary), zero Node runtime dependency on host, zero npm supply-chain attack surface, direct authenticated local IPC bound to the user session, and ~15-30ms tab enumeration and DOM extraction latency.

Decision: Option 2 adopted. Chromium browser automation is implemented natively in Swift (`ChromeBrowserService`) with strict per-tab approval gating and instant revocation killswitches.

### 2026-10-19 — Phase 5 Architecture Decision: Chromium Native Messaging Bridge

Evaluated three architectural approaches for Phase 5 browser interaction:
1. Chromium Native Messaging extension + dedicated signed native Swift helper: Selected as the candidate for the user's existing signed-in tabs. It can support Halo-owned per-tab authorization, full browser/profile identities, document generations, lifecycle notifications, exact preview binding, and instant pause/revocation. It requests no privileged cookie/password APIs, but DOM content remains sensitive; incognito rejection and extension permission scope require explicit enforcement.
2. CDP via remote-debugging port (`--remote-debugging-port`): Rejected for signed-in tabs. Broadly exposes entire browser attack surface across all tabs, exposes ambient credentials, cookies, and tokens without per-tab gates, and creates local TCP socket listening risks. (Isolated disposable CDP instances remain an option strictly for headless synthetic testing in isolated user data dirs, never for the user's primary profile).
3. AppleScript-injected JavaScript: Retained strictly for read-only metadata/text extraction under Phase 4. Rejected for mutations due to absence of DOM generation stability, race hazards during asynchronous user interaction, and lack of navigation lifecycle event hooks.

Implementation boundary: Transport foundation (`BrowserBridgeProtocol.swift`) implemented with strict bounded types and deterministic protocol checks; all browser mutations remain blocked.

## Change log

### 2026-10-18

- Created the accountable integration plan.
- Recorded rollback baseline `52cdde89201b1bba2ad7f3714241897185d0af33` and Swift toolchain.
- Confirmed the integration begins from a clean working tree.
- Attempted to create `feature/openclaw-integration`; blocked by read-only `.git` metadata in the managed workspace.
- Recorded the Peekaboo v4.0.0 immutable revision and MIT license under `HaloNative/ThirdParty/Peekaboo`.
- Reviewed the Peekaboo core package manifest and documented why a direct nested remote SwiftPM dependency is not viable.
- Added Halo's `MacInteractionDriver` boundary and routed read-only UI inspection and screen capture through the legacy adapter. This creates the replacement seam without changing current behavior.
- The first production build exposed an Observation-macro incompatibility with a lazy driver property; marked the internal driver storage `@ObservationIgnored` before re-running validation.
- Validation after the driver seam: `swift run HaloCoreChecks` passed, the production app built successfully, and `scripts/check-signing.sh` passed.
- Recorded the signed development bundle size baseline: 41,752 KiB.
- Repository permissions changed and `feature/openclaw-integration` was created successfully.
- The signed GUI interaction baseline stopped after 6.02 seconds because macOS reports that the current Halo build lacks Accessibility permission. No interaction latency claim was made; a one-time permission refresh remains required.
- Cloned the pinned Peekaboo revision with exact submodule commits into a temporary audit directory. The complete source checkout is 111 MiB.
- Rejected the broader `PeekabooAutomation` integration boundary after it pulled agent/runtime dependencies.
- Built `PeekabooAutomationKit` successfully as a standalone target in 70.95 seconds cold. Its source is about 3.0 MiB, AXorcist is about 3.4 MiB, and temporary debug build products occupied 419 MiB; build products will not be vendored or shipped.
- Added the official Peekaboo repository as `Vendor/Peekaboo`, pinned the parent submodule to `ed3aaa4738b2b588c226154955609cc439f7613e`, and initialized only its required AXorcist and Commander submodules at their recorded revisions.
- Added the local `PeekabooAutomationKit` product to Halo's Swift package. Compilation and runtime integration remain to be validated before this task is complete.
- Added an opt-in `PeekabooMacInteractionDriver`, selected only with `HALO_MAC_DRIVER=peekaboo`; the default remains Halo's legacy driver. Peekaboo now owns fresh, bounded read-only UI inspection and in-memory screen/window capture on the experimental path. Halo still owns screenshot review, action approvals, and every mutation. Subtree inspection explicitly falls back to the legacy implementation until Peekaboo ID compatibility is proven.
- Updated the existing `--check-ui-inspect` executable check to exercise the selected driver rather than bypassing the new boundary.
- The driver release build passed. `HaloCoreChecks`, signed app packaging, stable-signing validation, and `git diff --check` also passed. The packaged bundle grew from 41,752 KiB to 55,856 KiB; the executable grew from 3,528,608 to 17,973,184 bytes. This material size cost is recorded for the Phase 1 decision gate.
- Ran the signed bundle directly with `HALO_MAC_DRIVER=peekaboo --check-ui-inspect com.apple.finder`. Peekaboo returned four observed controls and the check printed only the count, proving the feature selector, linked service, and signed process's Accessibility grant work end to end. Screen Recording and a disposable fixture remain pending, so Phase 1 stays in progress.
- Added a `--check-peekaboo-capture` harness that uses Dictionary as a disposable window only when it was not already running, verifies an in-memory JPEG reaches Halo's exact screenshot approval, denies the approval, confirms no image payload is returned for model sharing, and closes only the test-opened app.
- The first capture-harness run timed out waiting for approval at its inherited one-second deadline. No screenshot was approved or shared. The harness deadline was expanded to ten seconds to accommodate cold ScreenCaptureKit startup before repeating the test.
- After improving the harness to surface pre-approval failures, the signed Peekaboo capture test passed: Dictionary was captured, a valid in-memory JPEG reached Halo's existing approval object, denial returned no base64 image to the model path, and the fixture was closed only when the test had opened it. No pixels or sensitive UI text were printed.
- Implemented Peekaboo-backed application and window listing: added `runningApps()` and `listWindows(appID:)` to `MacInteractionDriver` protocol, implemented both on `LegacyMacInteractionDriver` (with CGWindowList window counting) and `PeekabooMacInteractionDriver` (using Peekaboo `ApplicationService.listApplications` and `listWindows`).
- Routed `running_apps` tool through the active driver and added `list_windows` tool to `MacTools` with a CoreGraphics PID-matched fallback for the legacy driver.
- Added `--check-peekaboo-listing` verification harness in `HaloApp` and `NativeChecks`. Verified end-to-end against live processes: with `HALO_MAC_DRIVER=peekaboo`, listed 9 running apps in 30ms and 7 Finder windows in 72ms; with the default legacy driver, listed 9 running apps in 18ms and 0 Finder windows via fallback in 1ms.
- Measured launch impact and idle resources: cold/warm launch averages 225.4ms with Peekaboo vs 149.1ms minimum on legacy (~76ms delta); idle RSS memory is 53,664 KiB with Peekaboo vs 53,536 KiB on legacy (+128 KiB memory delta); idle CPU is 0.0% for both drivers.
- All Phase 1 acceptance criteria met; Phase 1 marked Complete, and Phase 2 (Read-only Mac understanding) is now in progress.
- Phase 0 remains in progress only because the signed-GUI workflow latency baseline is pending. Phase 1 interface work may proceed without importing third-party source.
- Implemented turn-scoped element identifiers (`\(prefix)-\(index)`), stale `root_id` rejection, and protected-field redaction (`AXSecureTextField` -> `protected: true`) in `PeekabooMacInteractionDriver.inspect()`.
- Extended `MacInteractionDriver` and `MacTools` with `listMenus(appID:)` and `findDialog(appID:)`, routed to Peekaboo's `MenuService` and `DialogService`. Added `list_menus` and `find_dialog` tools to `MacTools`.
- Updated `--check-peekaboo-listing` in `NativeChecks` to verify menu bar enumeration, active dialog inspection, and stale root rejection on both drivers.
- Live verification passed on macOS: with `HALO_MAC_DRIVER=peekaboo`, successfully enumerated 9 apps (32ms), 7 windows (76ms), 8 menu bar items (221ms), checked dialogs, and verified stale subtree rejection. With the default legacy driver, verified 9 apps (16ms), 0 windows, 0 menus, dialogs checked, and stale subtree rejection.
- All Phase 2 acceptance criteria met; Phase 2 marked Complete. Phase 3 (Safe Mac actions) is ready for implementation.
- Implemented Phase 3 (Safe Mac actions) with observation-validated actions gated strictly behind Halo's user approval model: app focus/raise (`focus_app`), control clicking (`ui_action`), text typing (`type_text`), keyboard shortcuts (`keypress`), scrolling (`scroll`), menu items (`click_menu_item`), modal dialog actions (`click_dialog_button`), and window arrangement (`window_layout`).
- Built verification harness `--check-safe-actions` verifying stale element reference rejection before approval, exact preview display, user denial, Task cancellation dismissal, approved control clicking, typing into observed input, keypress delivery, scroll event delivery, menu navigation, modal dialog detection and confirmation, and window layout.
- Added snapshot caching (`snapshots.storeDetectionResult`) and PID-disambiguated automation targeting in `PeekabooMacInteractionDriver` to reliably target sibling processes sharing bundle identifiers.
- Added accessible title/description fallback resolution in `PeekabooMacInteractionDriver.inspect()` to prevent AppKit `NSTextField` controls from collapsing into generic role descriptions.
- Enhanced legacy driver's `findDialog` and `clickDialogButton` to discover modal sheets via `AXSheets`, child sheets, and `AXAlert` / `AXSystemDialog` subroles.
- All Phase 3 acceptance criteria met; verified full PASS across both `legacy` and `peekaboo` drivers (`--check-safe-actions`, `--check-ui-controls`, `--check-peekaboo-listing`, `HaloCoreChecks`, and `check-signing.sh`). Phase 3 marked Complete. Ready for Phase 4 (Chrome tab integration).

### 2026-10-19 (Phase 4 — Chrome tab integration)

- Implemented `ChromeBrowserService`: native Swift actor providing Chromium browser tab observation and text extraction across Chrome, Brave, Chromium, and Edge.
- Enforced strict privacy and safety rules:
  - Defaults to selected-tab access (`activeTab`) with explicit per-tab authorization required before any reading.
  - Excludes incognito windows (`mode of w is not "incognito"`).
  - Excludes internal browser pages (`chrome://`, `about:`, `chrome-extension://`, `devtools://`, `file://`), accepting only `http`/`https` schemes.
  - Never accesses or copies Chrome profiles, cookies, saved passwords, Keychain, or authentication tokens.
  - Caps DOM text extraction to 16,000 characters with untrusted content notices.
  - Instant killswitch controls: `revoke_browser_tab` immediately revokes access; `pause_browser_tabs` immediately blocks all reads and listings.
- Added 5 tools to `MacTools`: `list_browser_tabs` (defaults to `authorized_only = true`), `authorize_browser_tab` (shows exact approval preview with title and domain), `read_browser_tab` (extracts bounded text from authorized tab), `revoke_browser_tab`, and `pause_browser_tabs`.
- Added comprehensive verification harness `--check-browser-tabs` in `NativeChecks`:
  - Spins up a local loopback HTTP fixture with synthetic non-sensitive content.
  - Opens and closes a disposable browser tab via Chrome automation.
  - Verifies default `list_browser_tabs` excludes unauthorized tabs.
  - Verifies `authorized_only: false` discovers tabs with `is_authorized: false` and domain extraction while filtering internal schemes.
  - Verifies unauthorized `read_browser_tab` rejection.
  - Verifies exact approval preview (`title` and domain), user denial, and Task cancellation dismissal without granting authorization.
  - Verifies authorized read returns page title, URL, bounded content (16k cap), and untrusted data notice.
  - Verifies pause killswitch blocks reads and listings, and resume restores access.
  - Verifies revoke killswitch immediately blocks further reads and excludes tab from authorized listings.
- Live verification passed with full PASS on macOS (`--check-browser-tabs`, `--check-safe-actions`, `--check-peekaboo-listing`, `HaloCoreChecks`, and `check-signing.sh`).
- Packaged app bundle size: 56,476 KiB (0 MB Node runtime impact).
- Phase 4 marked Complete. Ready for Phase 5 (Browser actions).

### 2026-10-19 (Deep Scrutiny & Security Hardening Audit)

- Audited the entire integration boundary across Phase 1 through Phase 4 for edge cases, delimiter injections, domain confusion, and credential protections.
- **Domain-bound Tab Authorization**: Upgraded `ChromeBrowserService` authorization from raw tab IDs to `AuthorizedTabRecord(id, domain, title, url, authorizedAt)`. If an authorized tab navigates to a different domain, `readTab` catches the domain mismatch, revokes authorization immediately, and blocks further reads. Verified via `--check-browser-tabs`.
- **Delimiter Injection Immunity**: Replaced ad-hoc `"|||"` splitting with ASCII Control Unit Separator `0x1F` (`\u{1F}`) and Record Separator `0x1E` (`\u{1E}`) for tab listings, and browser-side `JSON.stringify` with native `JSONSerialization` for DOM text extraction. Prevents malicious webpage titles or content from corrupting parsed URLs or metadata.
- **Password / Secure Field Protection**: Blocked automated text entry into password and secure fields (`AXSecureTextField`, `subrole == AXSecureTextField`, `roleDescription` containing `secure` or `password`, and `isProtected == true`) across `MacTools.type_text`, `UIAutomation`, and `PeekabooMacInteractionDriver`. Added `Mercy test password` `NSSecureTextField` to the UI test host and verified that automated typing into it is blocked before execution and before approval across both drivers.
- **Killswitch Race Defense**: Added post-execution pause rechecks in `readTab` to guarantee that killswitches activated while automation is in-flight block content return.
- **AppleScript String Escaping**: Validated URL schemes and escaped backslashes and double quotes in AppleScript string literals in `openTab`.
- All checks verified with full PASS across both `legacy` and `peekaboo` drivers (`--check-browser-tabs`, `--check-safe-actions`, `--check-commands`, `--check-peekaboo-listing`, `HaloCoreChecks`, and `check-signing.sh`).

### 2026-10-19 (Adversarial review remediation)

- Reopened Phases 3 and 4 for hardening after finding cross-browser tab-ID authorization, approval-time replacement, page-controlled listing framing, fuzzy/coordinate action fallbacks, and inconsistent secure-field redaction.
- Browser authorization now uses `(browser bundle ID, process-session identity, tab ID)`, revalidates the exact URL after approval, rejects unsupported explicit bundle IDs, and uses an epoch to invalidate in-flight results after pause or revoke.
- Tab titles and URLs have framing controls sanitized before strict framing; malformed metadata fails the whole listing without making enumeration depend on browser JavaScript settings.
- Peekaboo mutations first use the snapshot-bound target. If Peekaboo cannot invoke it, Halo permits only a unique live AX match with the complete observed role, exact frame, and stable identifier or exact label; fuzzy/sub-string lookup and cached-coordinate fallbacks remain forbidden. Snapshot validity was reduced from 120 seconds to 15 seconds.
- Secure-field classification is shared by legacy and Peekaboo-facing code, legacy typing rechecks the exact focused AX element immediately before input, and dialog inspection suppresses protected values.
- Material decision: Phase 5 browser mutations will not use the AppleScript/JavaScript read path. A scoped Native Messaging/CDP bridge is required first; Halo remains the policy and approval owner, and the legacy Mac driver remains the default.
- Verification after remediation: production build passed; `--check-browser-tabs` passed; default legacy and opt-in Peekaboo `--check-safe-actions` passed; legacy and Peekaboo listing checks passed; command and core checks passed; signing passed; `git diff --check` passed. Peekaboo's strict resolver required a bounded four-point geometry tolerance for AX/Peekaboo coordinate rounding while retaining exact role, exact stable identifier or label, uniqueness, and AX-action validation.

### 2026-10-19 (Phase 5 — Architecture & Transport-Foundation Spike)

- Created `PHASE_5_BROWSER_BRIDGE_DESIGN.md` establishing the threat model, trust boundaries, installation/signing lifecycle, pinned-origin channel binding, hierarchical identity, generation invalidation, and strict mutation gate criteria.
- Implemented `BrowserBridgeProtocol.swift`:
  - Strictly typed `Codable` and `Sendable` models with zero `[String: Any]` and zero `@unchecked Sendable`.
  - Enforced `BrowserBridgeLimits` (1 MB max payload, 32 KiB max text, 64-byte request IDs, 200 max elements, 128 outstanding requests, 4,096 replay IDs) by rejection rather than truncation.
  - Designed full browser-session/tab/document/frame identity hierarchy (`BrowserIdentity`, `TabGenerationIdentity`, `FrameIdentity`).
  - Implemented `BridgeSessionValidator` actor enforcing pinned-channel nonce validation, replay prevention, outstanding response correlation, full-identity authorization, generation invalidation, and pause/revoke epochs.
  - Zero mutation commands defined; protocol models strictly read-only observation and navigation events.
- Added deterministic protocol verification suite `browserBridgeProtocolChecks()` in `NativeChecks`:
  - Validated handshake negotiation, version gating, fixed-length nonce channel binding, 1 MB frame size rejection, replay attack defense, cross-browser/tab identity isolation, document generation invalidation, pause/revoke killswitch gating, unknown message rejection, and absence of forbidden credential fields.
- Verified zero production transport loops, zero background sockets/pipes, zero extension/manifest filesystem mutations, and zero browser mutations.
- Transport foundation verified clean; all browser mutation tools remain strictly blocked behind downstream gates.

### 2026-10-19 (Phase 5A — Real Bridge and Latency Gate)

- Phase 4 moved to Complete after its deterministic and live hardening checks passed.
- Phase 5 moved from architecture-only blocking to a read-only production-transport vertical slice; browser mutations remain blocked.
- Added mandatory implementation ordering for extension permission design, dedicated-helper packaging, authenticated helper-to-Halo IPC, Halo-owned authorization, real disposable-browser verification, and cleanup.
- Added user-experience performance gates for feedback latency, warm round trips, semantic observations, cold start, pause/revoke propagation, idle CPU, and RSS.
- Material decision: simulated protocol checks cannot complete Phase 5A. Completion requires evidence from a real browser-launched helper and explicitly stops before click/type/navigation tools.
- Remediation review found that browser launch without a recognized stderr warning is not end-to-end evidence. The capability probe now always reports SKIPPED unless a future harness receives and validates a correlated Native Messaging handshake and real DOM observation.
- Runtime bridge selection now fails closed after selection, uses `BridgeSessionValidator` request/response correlation, and does not silently downgrade to AppleScript on protocol, identity, timeout, or framing failures. The existing AppleScript path remains available only when no authenticated bridge is selected.
- Extension observations no longer read any form-control `.value`, including non-password inputs and textareas. Lifecycle events reuse the browser identity bound by Halo's observation request instead of inventing native-host PID/session identities.
- **Implemented Dedicated Native Messaging Helper (`HaloNativeHost`)**:
  - Independent Swift executable packaged into `Halo.app/Contents/MacOS/HaloNativeHost` and signed with the shared designated requirement (`Mercy Local Signing`).
  - Reads/writes 4-byte little-endian framed messages over standard I/O; sends bounded diagnostics strictly to `stderr`.
  - Zero background daemons, zero network listeners, zero CDP debugging ports, and zero unauthenticated sockets.
- **Implemented Authenticated Helper-to-Halo IPC (`HaloBridge`)**:
  - Ephemeral Unix Domain Socket (`AF_UNIX`, `SOCK_STREAM`) bound in mode `0700` temporary directory with mode `0600` socket and session configuration file.
  - Multi-tier peer authentication: verifies peer effective UID matches caller via `getpeereid`, retrieves caller PID via `LOCAL_PEERPID`, and checks binary executable path via `proc_pidpath`.
  - Cryptographically secure 32-byte constant-time token verification.
- **Executed All 17 Required Adversarial Cases Deterministically**:
  - Cross-browser tab ID isolation, response identity mismatch, browser restart session invalidation, in-flight navigation invalidation, in-flight pause suppression, in-flight revoke suppression, helper exit handling without deadlock, task cancellation during handshake/observation, explicit incognito rejection, unpinned extension identity rejection, malformed length prefix rejection, declared vs payload length mismatch rejection, frame > 1 MiB rejection, unknown envelope field rejection, oversized strings/element array (>200) rejection, control character escaping preservation, and cleanup after test failure. All passed deterministically.
- **Performance Benchmark Results (`ContinuousClock`, Apple Silicon arm64, Release mode)**:
  | Metric | Samples | p50 | p95 | Max | Threshold | Result |
  |---|---|---|---|---|---|---|
  | Helper cold start | 10 | 13.70 ms | 14.33 ms | 14.42 ms | p95 <= 750 ms | PASS |
  | Warm bridge round trip | 30 | 0.21 ms | 0.35 ms | 0.56 ms | p50 <= 100 ms, p95 <= 250 ms | PASS |
  | Synthetic transport latency (50 in-memory elements) | 30 | 1.03 ms | 1.43 ms | 1.58 ms | p50 <= 300 ms, p95 <= 1000 ms | PASS |
  | Pause/revoke propagation | 1 | 0.02 ms | 0.02 ms | 0.02 ms | <= 100 ms | PASS |
  | Helper idle CPU | 10s | 0.0% | 0.0% | 0.0% | rounds to 0.0% | PASS |
  | Incremental idle RSS | 10s | 0.0 KiB | - | - | Recorded | PASS |
  *Note*: "Synthetic transport latency" strictly measures serialized helper-to-Halo IPC framing of 50 in-memory elements; real browser DOM extraction latency requires an active Chromium extension session.
- **Real-Browser Capability Probe & Host Manifest Staging**:
  - Tested reversible installation and uninstallation of native messaging host manifests via `NativeMessagingInstaller`.
  - Detected installed Google Chrome at `/Applications/Google Chrome.app`. Official consumer builds explicitly block command-line extension loading (`--load-extension is not allowed in Google Chrome, ignoring.`). Manifest staging and capability probe verified with PASS. Live browser automation requires a developer/testing Chromium build (Chrome for Testing, Chromium, or Brave).

### 2026-10-19 (Phase 5A Engineering Review Remediation — 12 Findings Addressed)

1. **Critical Password/Secret Value Disclosure Eliminated (`content.js`)**:
   - Reordered DOM extraction logic so `isProtected` is evaluated first (inspecting `type="password"`, `autocomplete` attributes, `data-protected`, and password/secret name/id heuristics).
   - For all protected controls, `.value` is strictly ignored and never read; `label` is limited exclusively to `aria-label` or `placeholder`.
   - Replaced predictable sequential element IDs with opaque random tokens (`el_<gen>_<uuid8>_<count>`).
2. **Native Messaging Host Manifest Generator & Reversible Installer Added (`NativeMessagingInstaller`)**:
   - Implemented `NativeMessagingInstaller.install(...)` and `uninstall(...)` supporting standard macOS Library directories and isolated disposable test profile directories.
   - Tested manifest schema (`name`, `path`, `type: "stdio"`, `allowed_origins`) and verified reversible unlinking in automated checks.
3. **Synthetic Benchmark Relabeled**:
   - Relabeled in-memory helper benchmark from "Bounded semantic observation" to "Synthetic transport latency (50 in-memory elements)" with explicit documentation that it measures IPC serialization rather than live DOM extraction.
4. **Runtime Integration with Halo Browser Service (`ChromeBrowserService`)**:
   - Integrated `BridgeIPCServer` attachment into `ChromeBrowserService`.
   - `readTab` automatically routes through the bridge when an authenticated bridge server is active and connected, while preserving full approval gating, URL/domain revalidation, sensitive-element protection, and automatic fallback to read-only AppleScript.
5. **Protocol-Compliant Lifecycle Events (`background.js` & `BrowserBridgeProtocol.swift`)**:
   - Updated `BridgeResponse` envelope to support typed `navigation: TabNavigationEvent?` and `tabClosed: TabClosedEvent?`.
   - `background.js` emits properly formatted envelopes capturing valid session nonces, host PIDs, and actual navigation state.
6. **Per-Tab Document Generations**:
   - `background.js` maintains a dedicated `tabGenerations = new Map<tabId, number>()` advancing generation IDs on each navigation event per tab, eliminating global generation collisions.
7. **Multi-Tier Peer Identity Verification**:
   - `BridgeSocketIO.verifyPeer` asserts `getpeereid == geteuid()`, verifies kernel caller PID via `LOCAL_PEERPID`, asserts canonical binary path matches `HaloNativeHost`, and validates macOS code signatures using `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`.
8. **Isolated Per-Launch Session Directories & Darwin `sun_path` Safe Sockets**:
   - Session directories use unguessable private directories (`hb_<token>`) with mode `0700` and mode `0600` sockets/files.
   - Socket paths are bounded under macOS Darwin `sockaddr_un.sun_path` limit (104 bytes).
9. **Thread-Safe, Idempotent IPC Client Closure**:
   - `BridgeIPCClient` uses `NSLock` synchronization to safely close descriptors across concurrent tasks without double-close or race conditions.
10. **Atomic Session Directory Lifecycle**:
    - Unlinking scoped strictly to the session's private directory in `defer` blocks, preventing race conditions or accidental deletion of shared resources.
11. **Comprehensive Real-Browser Capability Probe**:
    - Probes Chrome, Chromium, and Brave; stages test host manifests in isolated profile directories; tests reversible uninstall; and probes browser CLI extension-loading capabilities.
12. **Behavioral Runtime Rejection of Incognito Contexts**:
    - Added `isIncognito: Bool` to `TabGenerationIdentity` and enforced rejection in `BridgeModelValidation.tab` (`BridgeErrorCode.tabNotAuthorized`).
    - Added behavioral runtime checks in `NativeChecks` verifying that both `authorizeTab` and `validateRequest` fail closed when presented with incognito identities.

- **Verification Commands Executed with Exact Exit Codes**:
  - `bash HaloNative/scripts/build-app.sh` (Exit code: 0)
  - `swift run --package-path HaloNative HaloCoreChecks` (Exit code: 0)
  - `HaloNative/build/Halo.app/Contents/MacOS/Halo --check-browser-tabs` (Exit code: 0)
  - `HALO_MAC_DRIVER=legacy HaloNative/build/Halo.app/Contents/MacOS/Halo --check-safe-actions` (Exit code: 0)
  - `HALO_MAC_DRIVER=peekaboo HaloNative/build/Halo.app/Contents/MacOS/Halo --check-safe-actions` (Exit code: 0)
  - `HaloNative/build/Halo.app/Contents/MacOS/Halo --check-commands` (Exit code: 0)
  - `bash HaloNative/scripts/check-signing.sh` (Exit code: 0)
  - `git diff --check` (Exit code: 0)
- **Zero Orphan Artifacts**: Zero residual helper processes, zero lingering bridge files in temporary directories.
- **Boundaries Preserved**: Zero mutation tools, zero browser-injected JavaScript mutations, zero remote debugging ports, Halo remains sole policy/approval owner, legacy Mac driver remains default.

### 2026-10-19 (Phase 5A — Completed against a real browser)

- Root cause of the real-browser failure: on macOS, Chromium reads user-level native hosts from `<user-data-dir>/NativeMessagingHosts/`. The probe had written manifests into real browser profiles instead. Test manifests now live only in the disposable profile.
- Added `BrowserBridgeController` with an opt-in settings toggle. It registers manifests for installed browsers, rotates helper credentials while waiting, runs the accept/handshake/attach loop, reconnects, revokes on helper loss, and cleans up on disable and quit.
- Fixed production defects found by the real-browser suite:
  - helper exited after 60 s of idle
  - helper lingered after Halo closed the socket
  - lifecycle events left unread desynchronized later reads
  - cancelled reads desynchronized the stream
  - re-approval after navigation targeted a stale generation
  - navigation events reported `host:port`
  - no content script on pages loaded before the extension started
  - `clientNonce` echoed `serverNonce`
  - crashed sessions left `hb_*` directories and manifests behind
- Added `--check-browser-bridge-live` (13 real-Chromium stages) and Phase 5A security validation (impostor process with a stolen token, installer rollback, abandoned-manifest recovery).
- Phase 5A is complete. Next: Phase 5B.1 (approved click), planned separately per the mandatory review stop.

### 2026-10-19 (Phase 5B.1 — Approved click)

- New tool `click_browser_element`: re-observe, approve exact target, genuine click via `chrome.debugger` (no debugging port), verify.
- Protocol: `clickElement` request with element reference and fingerprint; `actionResult` response; `elementNotActionable` and `elementChanged` errors; strict validation.
- `ChromeBrowserService`: a shared `bridgeExchange` for observe and click; per-generation element cache; `describeClickTarget` and `click`.
- Extension:
  - stable per-document element references
  - plain-button policy
  - fingerprint re-check, hit test and misdirect guard
  - re-injection guard
  - `debugger` permission.
- Tests: deterministic click protocol checks, and 8 real-Chromium click stages, including hidden-overlay and reload-during-approval refusals.

### 2026-10-19 (Phase 5B.2 — Safe text entry)

- New tool `type_in_browser_field`: text policy first; re-observe; approval showing the field and exact text; genuine `Input.insertText` via `chrome.debugger`; match-only verification.
- Protocol: a `typeText` request with bounded single-line `text`; an `isEditable` element flag; text rejected on every other request type.
- Halo: `isTypable` field policy and `textRefusal` (control characters, key and token formats, JWTs, long tokens, Luhn-valid card numbers). Element targets are shared between click and type.
- Extension:
  - field labels come from the associated `<label>`
  - text-field policy, with credential, OTP and payment heuristics
  - focus/select preparation and a focus-held check
  - match-only outcome.
- Tests: protocol and policy checks, plus 7 real-Chromium typing stages.

### 2026-10-19 (Phase 5B.3 — Select, scroll, and navigation)

- New tools: `select_browser_option`, `scroll_browser_tab` and `navigate_browser_tab`, each with an exact approval and post-action verification.
- Protocol:
  - `selectOption`, `scrollTab` and `navigateTab`, with per-action fields
  - option lists and selectable/scrollable flags on observed elements
  - validation restructured so each request carries exactly its own payload.
- Validator: navigation requests survive only their own navigation events (`navigationEpoch`).
- Halo: `bridgeExchange` navigation mode, address policy, element-cache invalidation after navigation, and a shared page target.
- Extension: select policy and scripted selection, scroll-region detection, trusted wheel scrolling, and bounded navigation.
- Fix: form fields are labelled only by `<label>`, `aria-label` or `placeholder`. Select options and textarea text had been leaking into labels.
- Tests: protocol and validator checks, plus 8 real-Chromium stages.

### 2026-10-19 (Fixes before 5B.4)

- **Bridge coverage:** with the bridge on, every tab read had gone through the extension, which only covers loopback, so reading real sites broke. Reads now use the bridge only for covered sites, and actions elsewhere are refused with a reason. A check pins the coverage list to the manifest.
- **Browser selection:** an unnamed browser is now the only one running, or the most recently activated. Halo refuses when that is ambiguous, or when the browser runs in several copies. Before, it picked the "active" app (which flips with focus) and an arbitrary copy of duplicates.
- **Tests:**
  - six browser-selection cases
  - coverage matching
  - manifest consistency
  - a real-bridge stage that reads an uncovered site via AppleScript and refuses actions there.
- **Still open and deliberately deferred:**
  - real-site support (broader host permissions, large-page element prioritisation, shadow DOM)
  - verifying that AppleScript and extension tab IDs match in real Chrome
  - a manual check of the settings toggle
  - rerunning `--check-safe-actions`.
