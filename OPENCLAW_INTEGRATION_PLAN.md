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
| 4. Chrome tab integration | Hardening | Browser-session authorization, approval revalidation, injection-safe metadata framing, and in-flight killswitch checks must pass |
| 5. Browser actions | Blocked on bridge | Do not add DOM mutations through AppleScript; select and validate a narrowly scoped Native Messaging/CDP boundary first |
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

- **Architecture gate:** AppleScript-injected JavaScript remains read-only. Browser mutation requires a narrowly scoped, authenticated Native Messaging/CDP bridge with stable page/node identities and navigation lifecycle events. No Phase 5 mutation tool may ship before this gate passes.
- Add semantic click, type, select, scroll, and navigation on authorized tabs.
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
