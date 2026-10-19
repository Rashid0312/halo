# Phase 5: Chromium Native Messaging Bridge Architecture & Security Design

**Document Version**: 1.0.0  
**Status**: Architecture Spike & Foundation Specification (Mutations Blocked)  
**Date**: 2026-10-19  
**Author**: Halo Native Core Team  

---

## 1. Executive Summary & Architecture Decision

### 1.1 Decision
Halo adopts **Chromium Native Messaging with a pinned-origin, signed native Swift helper** as the candidate architecture for future browser automation on user-authorized tabs. Chromium authenticates the extension origin when launching the helper; helper-to-Halo authentication remains a release gate.

### 1.2 Comparison & Rejection Analysis

| Criterion | 1. Native Messaging Bridge (Adopted) | 2. CDP via Debugging Port (Rejected) | 3. AppleScript Injected JS (Phase 4 Baseline) |
|---|---|---|---|
| **User's Existing Signed-in Tabs** | Works directly on existing tabs via extension content scripts | Requires launching a separate browser or exposing debug port on active browser | Works directly via AppleScript `execute javascript` |
| **Exposure of Ambient Credentials** | No privileged cookie/password APIs are requested. DOM content remains sensitive because isolated-world scripts share the page DOM. | **Fatal**: Local TCP debugging port exposes full cookies, passwords, and sessions to any local app | Does not call credential stores, but returned DOM text can still be sensitive |
| **Element & Page Generation Identity** | **Strong**: Isolated content scripts assign stable, generation-bound tokens per page lifecycle | **Strong**: Node IDs and execution contexts provided by CDP | **None**: No stable node IDs; SPA DOM updates cause selector drift |
| **Navigation Lifecycle Events** | Extension service-worker `webNavigation` events can invalidate generation IDs, subject to audited permissions and event ordering | **Real-time**: CDP `Page.frameNavigated` events | **Poor**: Polling-based URL checks create a TOCTOU race window |
| **Network & Socket Attack Surface** | Browser-managed stdin/stdout to the helper; helper-to-Halo IPC remains an unresolved security gate | **High**: Unauthenticated or token-authenticated local TCP socket open to localhost | **None**: IPC via Apple Events |
| **Incognito & Profile Isolation** | Must be enforced explicitly: reject incognito contexts and verify the extension is not allowed in incognito; default browser settings are not a security boundary | **Complex**: Requires strict profile directory separation | **Enforced**: Filtered via AppleScript window `mode != "incognito"` |
| **macOS Code Signing & Deployment** | **Standard**: Signed & notarized native helper in standard OS Application Support directory | Requires managed Chromium command-line policies or separate binaries | Uses system `osascript` |

**Conclusion**: Native Messaging provides the necessary element generation stability, navigation lifecycle interception, and sandboxed stdio transport without exposing a dangerous local TCP debugging port or requiring ambient credential extraction. AppleScript remains Halo's read-only fallback.

---

## 2. Threat Model & Trust Boundaries

```
┌────────────────────────────────────────────────────────────────────────┐
│ UNTRUSTED WEB CONTENT (Untrusted World)                                │
│ Web Pages, Third-party Scripts, IFrames, Malicious DOM                 │
└────────────────────────────────────────────────────────────────────────┘
                                    │
               (Strict DOM Boundary / Isolated World)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ HALO EXTENSION (Isolated World / Background Service Worker)            │
│ - Requests no privileged cookie/password APIs; DOM remains sensitive   │
│ - Ephemeral element token generation bound to documentGenerationID     │
│ - Navigation lifecycle listeners (webNavigation)                       │
└────────────────────────────────────────────────────────────────────────┘
                                    │
           (Browser-launched Stdio / Manifest-Pinned Extension Origin)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ HALO NATIVE MESSAGING HOST (Signed Native Swift Helper)                 │
│ - Framing validator (1 MB max payload)                                 │
│ - Pinned-origin channel binding and bounded frame validation           │
│ - Helper-to-Halo IPC is not yet selected or implemented                │
└────────────────────────────────────────────────────────────────────────┘
                                    │
             (Strict Actor Isolation / Epoch Gating)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│ HALO APPLICATION (Policy & Approval Owner)                             │
│ - Sole authority for user approval prompts                            │
│ - Access epoch & killswitches (pause/revoke immediately block)         │
│ - Human-readable preview binding before dispatch                       │
└────────────────────────────────────────────────────────────────────────┘
```

### Trust Boundary Rules:
1. **The Web Page is Hostile**: Page scripts, DOM contents, titles, and URLs are untrusted input. They can attempt delimiter injection, prompt injection, frame spoofing, or clickjacking.
2. **The Extension is Semi-Trusted**: Even if an extension context is compromised, it cannot authorize actions or bypass user prompts. Its DOM claims remain untrusted input.
3. **Halo is the Sole Policy Owner**: All authorization records, access epochs, and approval dialogs exist exclusively within Halo's native memory. Neither the extension nor the native host can declare a tab authorized.

---

## 3. Component Roles & Responsibilities

- **Halo Native App**: Maintains `authorizedTabs`, `accessEpoch`, user approval UI, model dispatch, and killswitches. Evaluates tool calls against strict safety policies.
- **Native Messaging Host**: Minimal native Swift helper executable registered with Chromium. Reads and writes standard 4-byte length-prefixed JSON frames over stdin/stdout. Performs strict frame, schema, freshness, and channel-binding checks.
- **Chromium Extension**: Observes semantic structure, assigns opaque element tokens, and reports navigation events. Its exact optional-host-permission/`activeTab` strategy is a release gate and must not be inferred from Halo's native authorization state.
- **Browser**: Isolates web processes, runs the extension runtime, and enforces the manifest's allowed extension origins. Halo must independently reject incognito contexts and verify incognito access is disabled.
- **Model**: Generates tool proposals based on read-only observations. Has no direct execution capability.

---

## 4. Installation, Signing & Host Registration

1. **Manifest Location**:
   Registered only in user-scoped Application Support:
   - Google Chrome: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.halo.browser_bridge.json`
   - Brave: `~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/app.halo.browser_bridge.json`
   - Chromium: `~/Library/Application Support/Chromium/NativeMessagingHosts/app.halo.browser_bridge.json`
   - Edge: `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/app.halo.browser_bridge.json`
2. **Allowed Origin Pinning and Path Installation**:
   The manifest must explicitly define `allowed_origins` with the exact, pinned extension ID:
   ```json
   {
     "name": "app.halo.browser_bridge",
     "description": "Halo Native Messaging Bridge Host",
     "path": "/Applications/Halo.app/Contents/MacOS/HaloNativeHost",
     "type": "stdio",
     "allowed_origins": [
       "chrome-extension://mfnoiamhnajnnieagdpagkebabpnkdmc/"
     ]
   }
   ```
   The absolute `path` is generated only during an explicit opt-in install and must be refreshed if the app moves. The browser launches a dedicated helper executable, not the GUI application binary.
   As built in Phase 5A (§16.5), `path` points to the per-session launcher `$TMPDIR/hb_<random>/halo_host_launcher.sh`, which `exec`s the bundled helper with the session directory. Edge is not registered yet.
3. **Code Signing**: The helper is signed and notarized with Halo. Chromium's manifest lookup does not itself verify the macOS signature, so Halo's installer/updater must verify the helper's designated requirement and Team ID before registration and use.

---

## 5. Pinned-Origin Channel Binding & Handshake Protocol

1. **Session Nonce**: The eventual host/Halo session owner generates a cryptographically random 32-byte nonce. The nonce binds freshness to Chromium's already origin-authenticated Native Messaging channel; it does not independently authenticate the extension.
2. **Challenge / Response**:
   - Halo transmits `BridgeHandshakeChallenge(version: 1, serverNonce: hex, hostProcessID: pid, issuedAt: date)`.
   - Extension replies with `BridgeHandshakeResponse(version: 1, serverNonce: hex, clientNonce: hex, extensionID: id, acceptedAt: date)`.
3. **Pinned Peer and Constant-Time Verification**: The exact extension ID comes from the installed manifest's `allowed_origins`; the response must repeat that pinned ID and the nonce is compared without content-dependent byte comparisons.
4. **No Replay**: Every outbound request carries a unique `requestID` (UUIDv4) and the established `sessionNonce`. Duplicate or replayed request IDs immediately abort the session.

---

## 6. Message Framing & Size Limits

- **Chromium Native Messaging Wire Format**: 4-byte little-endian unsigned integer length prefix on supported macOS Chromium builds, followed by UTF-8 encoded JSON.
- **Strict Size Limits**:
  - Maximum Frame Size: **1,048,576 bytes (1 MB)**. Frames exceeding this limit are dropped immediately.
  - Maximum Single Text Field: **32,768 bytes (32 KB)**.
  - Maximum Observed Elements per View: **200 elements**.
- **Schema Strictness**: All messages conform to bounded Swift `Codable` structs. Unknown top-level envelope fields are rejected; nested values receive explicit semantic and size validation. Untyped protocol payloads are not exposed to policy code.

---

## 7. Hierarchical Identities & Page Generation Tracking

To prevent cross-context confusion, every reference is qualified by the complete hierarchy below:

```
BrowserIdentity (Bundle ID, Process Session ID, PID)
  └── TabIdentity (Numeric Tab ID)
        └── DocumentGenerationIdentity (Document Generation ID, URL, Domain)
              └── FrameIdentity (Frame ID, isMainFrame)
                    └── ElementToken (Opaque, generation-bound string)
```

### Invalidation Invariants:
1. **Document Generation ID**: A 64-bit integer monotonically incremented whenever the tab navigates, reloads, or replaces its document.
2. **Instant Stale Invalidation**: Any element token issued under `generation N` is strictly invalid under `generation N + 1`. Requests referencing prior generations fail closed with `staleDocumentGeneration`.
3. **Subframe / IFrame Isolation**: Subframes receive their own `frameID`. Top-level navigation invalidates all subframe references simultaneously.

---

## 8. Per-Tab Authorization Lifecycle

```
[ Discovered Tab ] ──> User Clicks "Allow" ──> [ Authorized Tab Record ]
                             │                            │
                     (Approval Dialog)                    │ (Navigation or Restart)
                             │                            ▼
                             └─────────────────> [ Immediate Revocation ]
```

1. **Discovery**: `list_browser_tabs` returns tabs with metadata only. Content extraction is blocked.
2. **Approval**: User must confirm an explicit native approval modal displaying:
   - Target website domain (e.g. `github.com`)
   - Complete page title
   - Target browser application
3. **Binding**: Authorization creates an `AuthorizedTabRecord` keyed by `(browserBundleID, browserSessionID, tabID)`.
4. **Automatic Revocation**:
   - Any navigation away from the approved domain revokes authorization instantly.
   - Any browser restart revokes authorization instantly.
   - Any tab replacement revokes authorization instantly.

---

## 9. Pause & Revoke Concurrency Invariants

1. **Access Epoch**: Halo maintains a monotonic 64-bit `accessEpoch`. Any pause (`pause_browser_tabs`) or revoke (`revoke_browser_tab`) immediately increments `accessEpoch`.
2. **Pre- and Post-Await Epoch Validation**:
   - Epoch is captured before dispatching a bridge request.
   - When a response arrives, Halo verifies `currentEpoch == initialEpoch`. If the epoch changed while the request was in-flight, the response is discarded and an error returned to the caller.
3. **Suppressed Delivery**: Discarded in-flight responses do not pass data to the model or UI; the transport may transiently hold the bounded response bytes before validation.

---

## 10. Exact Action Preview Binding (For Future Phase 5 Mutations)

*Note: Mutation tools are currently blocked. When designed in Phase 5, they must enforce:*
1. **Pre-Action Re-Observation**: Before presenting an action approval prompt to the user, the element must be re-observed in the live DOM.
2. **Visual & Identity Confirmation**: The prompt must show the exact element text, role, bounding box preview, and URL.
3. **Execution Guard**: If the target element has moved, altered text, or changed disabled state between preview and execution, the action aborts without modifying the DOM.

---

## 11. Allowed Observation Messages vs. Explicitly Forbidden Messages

### Allowed Observation Messages (Read-Only Spike):
- `handshakeChallenge` / `handshakeResponse`: Initial session establishment.
- `observeTabRequest` / `tabObservedEvent`: Extraction of semantic structure and accessible text from authorized tabs.
- `pauseTabsRequest` / `revokeTabRequest`: Immediate killswitch propagation.
- `tabNavigationEvent`: Real-time notification of navigation to trigger instant invalidation.
- `tabClosedEvent`: Real-time notification of tab closure.

### Explicitly Forbidden Messages:
- `evalJavascript`: Execution of arbitrary string-based JavaScript is strictly prohibited.
- `readCookies` / `getCookies`: Access to cookies is impossible by protocol design.
- `readSavedPasswords`: Access to password stores is impossible by protocol design.
- `dumpStorage` (localStorage / sessionStorage / IndexedDB): Storage access is forbidden.
- `captureScreenshot`: Native screenshot facilities must be governed by Halo's existing `ScreenService`, not by browser extension script injection.
- `fileUpload` / `fileDownload`: File system mutations are forbidden.
- Any mutation action (`click`, `type`, `select`, `submit`) is **strictly forbidden** until the Phase 5 mutation gate is passed.

---

## 12. Audit Events & Logging Safeguards

To prevent credential and privacy leakage into logs or telemetry:
1. **Zero Text / DOM in Audit Events**: Audit records contain only timestamp, event type, browser bundle ID, numeric tab ID, document generation ID, and website domain (e.g., `domain: "github.com"`).
2. **No Path or Query Parameters**: URLs in audit events are stripped of query parameters and sensitive fragments.
3. **No Screen Pixels or Keystrokes**: Neither input values nor page text are recorded in audit logs.

---

## 13. Threat & Failure Analysis

| Scenario | Defense Mechanism | Result |
|---|---|---|
| **Hostile Page Script Delimiter Injection** | Strict JSON framing with typed Codable schemas; no delimiter splitting (`\u{1E}`, `\u{1F}`, `|||`) | Payload remains data; outer schema cannot be corrupted |
| **Tab Navigates While Approval is Open** | Halo re-validates `url`, `domain`, and `documentGenerationID` after approval click | Fails closed: `"The browser tab changed while approval was open"` |
| **Unpinned Extension Connection** | Chromium enforces the native-host manifest's exact `allowed_origins`; nonce exchange adds freshness/channel binding | Chromium does not launch this host for an unlisted extension origin |
| **In-Flight Pause Killswitch Race** | `accessEpoch` check after asynchronous response return | Response discarded; no content returned |
| **Browser Restart Reusing Tab ID** | Session identity includes process launch timestamp (`pid:launchDate`) | Prior authorizations fail closed; no session inheritance |
| **Password Field Interaction Attempt** | Extension `isProtected` is advisory only; native policy blocks sensitive controls and mutation requires a fresh, independently checked preview | Tool execution fails closed when sensitivity cannot be ruled out |

---

## 14. Rollback & Removal Procedure

If the Native Messaging bridge must be deactivated or uninstalled:
1. **Host De-registration**: Delete the manifest JSON file from `~/Library/Application Support/<Browser>/NativeMessagingHosts/app.halo.browser_bridge.json`.
2. **Extension Removal**: The user uninstalls the Halo extension from `chrome://extensions`.
3. **Zero Orphaned Processes**: Because the host is launched on-demand by the browser via standard stdio, closing Chrome or deleting the manifest leaves no background daemon running.
4. **Fallback to Read-Only AppleScript**: Once production routing exists, disabling the bridge must leave the current approval-gated `ChromeBrowserService` read-only path available.

---

## 15. Gate Criteria Required Before Any Mutation Tool is Enabled

Before any mutation tool (`click_browser_element`, `type_browser_text`, `navigate_browser_tab`) is introduced:
1. `PHASE_5_BROWSER_BRIDGE_DESIGN.md` must be reviewed and signed off by the primary engineer.
2. `BrowserBridgeProtocol.swift` must pass all deterministic unit and schema checks.
3. A real, pinned extension and native host must demonstrate isolated-world DOM token generation and real-time navigation lifecycle invalidation in a standalone test harness.
4. Mutation preview binding and defense-in-depth secure-field exclusion must pass adversarial tests; extension-provided `isProtected` is never the sole policy signal.
5. Halo's approval engine must remain the sole executor and gatekeeper.
6. The extension permission model (`activeTab` versus optional host permissions), explicit incognito rejection, dedicated-helper lifecycle, and authenticated helper-to-Halo IPC must be implemented and adversarially verified.

---

## 16. Phase 5A Engineering Specification: Real Read-Only Bridge Vertical Slice

Status: **complete** (2026-10-19). Everything in this section describes the code as built and verified against a real Chromium browser.

### 16.1 Components
| Component | Location | Role |
|---|---|---|
| Protocol | `HaloNative/Sources/HaloBridge/BrowserBridgeProtocol.swift` | Bounded `Codable` envelopes, handshake, identities, validators. No mutation messages. |
| IPC + installer | `HaloNative/Sources/HaloBridge/BrowserBridgeIPC.swift` | `BridgeIPCServer`, `BridgeIPCClient`, peer verification, `NativeMessagingInstaller`, abandoned-session sweep. |
| Helper | `HaloNative/Sources/HaloNativeHost/main.swift` → `Halo.app/Contents/MacOS/HaloNativeHost` | Browser-launched stdio relay to Halo's socket. Signed with Halo's identity by `scripts/build-app.sh`. |
| Controller | `HaloNative/Sources/Halo/BrowserBridgeController.swift` | Opt-in lifecycle: register, accept, handshake, attach, reconnect, tear down. |
| Policy | `HaloNative/Sources/Halo/ChromeBrowserService.swift` | Halo remains the only authority for tab authorization; `readTab` routes through the bridge when attached. |
| Extension fixture | `HaloNative/Fixtures/BrowserBridgeExtension/` | Minimal MV3 development extension. |
| Checks | `NativeChecks.swift`, `BrowserBridgeLiveChecks.swift` | `--check-browser-tabs` and `--check-browser-bridge-live`. |

### 16.2 Code Signing & Peer Identity
- `HaloNativeHost` is signed with the same identity as `Halo.app`.
- Chromium does **not** verify a native host's signature; it only executes the manifest path. Halo therefore verifies every connecting peer itself, in this order:
  1. UID: `getpeereid`.
  2. Kernel PID: `LOCAL_PEERPID`.
  3. Canonical executable path equals the bundled helper.
  4. The running code satisfies the helper's designated requirement.
- A non-Halo process holding a valid session token is rejected (security validation check).

### 16.3 Development Extension Identity
- Extension ID `mfnoiamhnajnnieagdpagkebabpnkdmc`, derived from the fixed public key in `manifest.json` (`BrowserBridgeController.developmentExtensionID`).
- Manifests set `allowed_origins` to exactly `chrome-extension://mfnoiamhnajnnieagdpagkebabpnkdmc/`.
- The helper forwards the origin Chromium passes it. Halo rejects any other origin at authentication.
- The handshake rejects a mismatched `extensionID` and a `clientNonce` that echoes the `serverNonce`. The extension generates a random 32-byte client nonce.

### 16.4 Browser for Verification
- Consumer Google Chrome ignores `--load-extension`, and Chrome for Testing did not start the MV3 worker in our configuration.
- Verification uses an unbranded Chromium snapshot at `.local-tools/chromium/` (git-ignored). Verified with Chromium 158.0.8113.0.
- It must run headful: the extension worker does not start headless.
- Each run uses a disposable `--user-data-dir`.

### 16.5 Manifest Installation & Removal
- **Tests:** on macOS, Chromium looks up user-level native hosts in `<user-data-dir>/NativeMessagingHosts/`, so test manifests live only inside the disposable profile and never touch real browser profiles.
- **Production:** the manifest is written only while the opt-in is on. It goes into `~/Library/Application Support/{Google/Chrome, Chromium, BraveSoftware/Brave-Browser}/NativeMessagingHosts/`, and only for browsers that have a profile folder.
- **No overwrite:** an existing manifest is never overwritten. If any directory fails, every manifest already written in this attempt is removed.
- **Abandoned-manifest recovery:** a manifest is replaced only when it is provably Halo's own and abandoned. That means it launches `$TMPDIR/hb_*/halo_host_launcher.sh`, and that session's Halo process no longer exists.
- **Removal:** manifests are removed when the bridge is disabled and on app quit (`shutdownForTermination`).

### 16.6 Extension Permissions
- Permissions: `activeTab`, `tabs`, `nativeMessaging`, `scripting`, and from Phase 5B.1 `debugger` (§17.2).
- Host permissions: `http://127.0.0.1/*` and `http://localhost/*` only.
- `scripting` is used solely to inject the read-only `content.js` into a page that has none. That happens for pages loaded before the extension started, and host permissions still confine it to loopback.
- Not used: `cookies`, `storage`, `history`, `downloads`, `webRequest`, `<all_urls>`.
- `"incognito": "not_allowed"`, plus runtime rejection.

### 16.7 Helper-to-Halo IPC
- **Session directory:** a per-session `$TMPDIR/hb_<random>` directory with mode `0700`. It holds:
  - the socket `s.sock` (`0600`)
  - the launcher `halo_host_launcher.sh` (`0700`)
  - `session.json` (`0600`), written atomically.
- **Credential rotation:** the helper rejects a `session.json` older than 60 s. While the bridge waits for a browser, the controller rotates the auth token and timestamp every 30 s, so a lazily launched helper always finds fresh credentials. The session nonce does not change.
- **Accept loop:** the controller accepts in 2 s slices, because `acceptConnection` holds the server actor while it waits.
- **Helper lifetime:** the helper's lifetime is bound to Halo's socket.
  - An idle connection never times out: the helper waits for readability, then reads each frame with a 10 s bound.
  - When Halo closes the socket, the helper exits even if its stdin read is still blocked.

### 16.8 Lifecycle and Policy Rules
- **Connection:** handshake, then the extension announces eligible tabs, then the controller attaches the server to `ChromeBrowserService`.
- **Helper loss:** detected by a non-consuming hang-up check every 500 ms. On loss Halo:
  1. detaches the server
  2. revokes **all** authorizations (a new worker or browser restarts generation counting)
  3. rotates credentials
  4. waits for the extension's capped-backoff reconnect (1 s doubling to 30 s).
- **Reads:** `readTab` first applies pending navigation and close events, then sends a single request and reads until the response with the matching `requestID` arrives. Events and abandoned responses met along the way are applied or discarded, so cancellation never desynchronizes the stream. Only one bridge read runs at a time.
- **Generations:** document generations are tracked for every tab the extension has bound, whether or not it is authorized, so re-approving a tab after navigation targets the live document.
- **Navigation:** authorization is domain-bound, as in Phase 4. Same-site navigation updates the recorded URL; a cross-domain move revokes. Navigation events report `hostname`, not `host:port`.
- **Extension-side check:** after observing, the extension re-checks the generation and URL, and returns a stale-generation error if the document changed during the observation.

### 16.9 Cleanup
- **Normal exit:** every run removes its manifest, profile, session directory, socket and processes.
- **Crash recovery:** a crash cannot run cleanup, so:
  - `BridgeSessionConfig.removeAbandonedSessionDirectories()` removes `hb_*` directories whose owner process is gone. It runs when the bridge starts and before the browser checks.
  - the checks also stop any test Chromium still using a disposable `halo-bridge-live-*` or `halo-browser-probe-*` profile.

### 16.10 Verification
| Command | Covers |
|---|---|
| `HaloNative/build/Halo.app/Contents/MacOS/Halo --check-browser-tabs` | Protocol checks; helper relay; 17 adversarial cases; security validation (impostor process, installer rollback, manifest recovery); helper benchmarks; real-Chromium smoke handshake and observation; Phase 4 integration including the first-visible-activity measurement |
| `HaloNative/build/Halo.app/Contents/MacOS/Halo --check-browser-bridge-live` | 13-stage real-Chromium lifecycle through production code |

The 13 stages are:
1. opt-in connect and observe
2. same-site navigation
3. reload
4. pause during a read
5. revoke during a read
6. cancel during a read
7. cross-domain navigation
8. tab close
9. helper SIGKILL and reconnect
10. extension service-worker restart
11. 65 s connected idle
12. browser restart
13. disable, with a residue check.

- **What is real and what is stubbed:** in the lifecycle suite only the AppleScript tab listing is stubbed, fed from the extension's own announcements. The test browser is driven over the DevTools protocol, on a disposable profile, by the test harness only. Production never opens a debugging port.
- **Waits:** waits are bounded condition polls, not fixed sleeps.
- **Interruption tests:** pause, revoke and cancel are retried at staggered offsets until each one lands while a read is actually in flight.

### 16.11 Measured Results (2026-10-19, Apple M1, macOS 26.5.1, Chromium 158.0.8113.0)
| Metric | Samples | p50 | p95 | Max | Gate | Result |
|---|---|---|---|---|---|---|
| DOM observation via production `readTab` (round trip) | 30 | 1.24 ms | 1.85 ms | 2.01 ms | p50 ≤ 300 ms, p95 ≤ 1000 ms | PASS |
| First visible Halo activity after request accepted | 10 | 0.031 ms | 0.051 ms | 0.066 ms | ≤ 500 ms | PASS |
| Warm bridge round trip (helper IPC) | 30 | 0.20 ms | 0.25 ms | 0.52 ms | p50 ≤ 100 ms, p95 ≤ 250 ms | PASS |
| Helper cold start | 10 | 13.96 ms | 15.32 ms | 15.77 ms | p95 ≤ 750 ms | PASS |
| Pause/revoke propagation (deterministic) | 1 | 0.02 ms | – | – | ≤ 100 ms | PASS |
| Cold connect (browser launch → connected) | 1 | 1.3–3.0 s across runs | – | – | Recorded | – |
| Helper loss detection | 1 | 0.2–0.5 s (500 ms poll) | – | – | ≤ 1 s | PASS |
| Warm reconnection (helper killed → re-handshaked) | 1 | 1.35 s | – | – | ≤ 5 s | PASS |
| Connected idle, helper | 65 s | 0.00% CPU | 5.2 MiB RSS | – | CPU < 1% | PASS |
| Connected idle, Halo | 65 s | 0.01% CPU | – | – | CPU < 2% | PASS |

### 16.12 Known Limits Carried Forward
- **Loopback only:** the development extension only covers loopback pages. A production extension identity, its distribution, and broader host permissions are release-hardening decisions.
- **Ambiguous default browser (fixed 2026-10-19):** with no browser named, Halo uses:
  - the only supported browser running, or
  - the one the user most recently activated (`BrowserActivityTracker`).

  It refuses when that is unknown or when several copies of the chosen browser are running.
- **Bridge coverage (fixed 2026-10-19):** reads go through the bridge only for sites the extension's `host_permissions` cover (`ChromeBrowserService.bridgeHostPermissions`, checked against the manifest). Every other site keeps the AppleScript read path, so enabling the bridge never breaks reading. Browser actions on uncovered sites are refused with a clear reason.
- **Mutations:** Phase 5A itself has none. Phase 5B.1 adds one approved click (§17).


## 17. Phase 5B.1: Approved Click

Status: **complete** (2026-10-19). The first browser mutation: one approved click on one plain button.

### 17.1 Flow
1. **Observe.** `read_browser_tab` (bridge path) returns element references, and each element carries a `clickable` flag. References are opaque (`el_<generation>_<16 hex>`). The content script keeps them stable for the life of the document. A new document gets a new content script, so an old reference can never resolve again.
2. **Re-check before asking.** `click_browser_element(tab_id, element_id)` → `ChromeBrowserService.describeClickTarget` re-observes the tab. The element must be in that fresh observation and pass Halo's own policy (`isClickable`). The extension's `isActionable` flag is required too, but it is never sufficient on its own.
3. **Approve.** The approval preview shows the domain, the page title, and the element's role and label ("Click the button “…”").
4. **Click.** After approval, `click` sends a `clickElement` request bound to the approved document generation, with the expected fingerprint (tag, role, label). Halo refuses first if the generation moved.
5. **Re-verify in the extension:**
   1. The tab, its URL and the generation are unchanged, and the tab was observed this session.
   2. It attaches `chrome.debugger` to that tab only.
   3. The content script re-resolves the element, matches the fingerprint, re-applies the policy and scrolls it into view.
   4. It waits two frames for layout to settle (the debugger infobar can shift the page).
   5. It hit-tests the centre point with `elementFromPoint` and arms a one-shot guard.
   6. It re-checks the page.
   7. It sends a genuine left click (`Input.dispatchMouseEvent`).
   8. It confirms the outcome.
   9. It always detaches.
6. **Report.** Halo matches the `actionResult` to the request's tab and document, re-observes, and returns the verified result to the model.

### 17.2 Decision: `chrome.debugger` for trusted input
- **Why:** scripted `element.click()` produces untrusted events that some sites ignore, and it clicks hidden elements regardless of what the user would see. Genuine input requires the DevTools input domain.
- **How it fits the design:** §1 rejects launching browsers with a remote-debugging **port**, because any local process can connect to one. `chrome.debugger` opens no port. It is reachable only by this pinned extension, Chrome shows a visible "started debugging this browser" infobar while it is attached, and Halo attaches it only to the authorized tab, only after approval, only for one click.
- **Precedent:** the same approach is used by the ChatGPT/Codex Chrome extension, which declares `debugger` alongside `nativeMessaging`.
- **Cost:** the `debugger` permission is powerful and carries a strong install warning. Our code is the only limit on what the attachment does, so the extension issues only the three `Input.dispatchMouseEvent` commands for an approved click.

### 17.3 Policy (5B.1)
| Allowed | Refused before approval |
|---|---|
| `<button type="button">`, `role="button"` on a non-form, non-link element; enabled, visible, not protected | links (5B.3); any element inside a `<form>` or link (submission is 5B.4); disabled or `aria-disabled`; protected/password-like; hidden or zero-size |

At click time the click is also refused, with nothing clicked, when:
- the element was removed or its label, role or tag changed
- another element covers its click point (a hidden overlay)
- the page navigated or reloaded after approval
- the reference came from a previous document.

**Misdirect guard:** while the guard is armed, any trusted pointer or click event landing outside the approved element is cancelled with `preventDefault` and `stopImmediatePropagation`, and the click is reported as failed.
- *Limit:* the page's own window-capture listeners registered earlier still run first. The hit test is the primary defence; the guard is secondary.

### 17.4 Verification
| Check | Covers |
|---|---|
| `--check-browser-tabs` → "Phase 5B.1 click protocol" | Incomplete click requests, malformed element references, element fields on non-click requests, and a click result for a different tab are all rejected. |
| `--check-browser-bridge-live` → 8 "5B.1" stages | The model-facing `click_browser_element` tool, with real approvals, against real Chromium. |

The 8 live stages:
1. element flags are correct
2. approved click lands once, is genuine (`isTrusted`) and is verified
3. denied click does nothing
4. submit, link, disabled and password are refused with no approval prompt
5. element renamed during approval is refused
6. hidden overlay is refused
7. reload during approval is refused
8. stale reference is refused.

In each refused case the page's own counters confirm that nothing was clicked.

### 17.5 Limits
- **Loopback only:** the development extension still covers loopback pages only.
- **Main frame only:** a click inside an iframe is not supported.
- **Zoom:** the click point uses CSS pixels in the main-frame viewport, which matches `Input.dispatchMouseEvent`. Not yet tested under page zoom.
- **Unconfirmed after navigation:** a click that makes the page navigate cannot be confirmed by the guard, because the document is replaced. It is reported as `verified: false`, "Click sent; the page changed before it could be confirmed."

## 18. Phase 5B.2: Safe Text Entry

Status: **complete** (2026-10-19). Replaces one plain text field's contents with approved text. Nothing is ever submitted.

### 18.1 Flow
1. **Observe.** `read_browser_tab` marks each element `typable` or not. Fields are named by their associated `<label>`, then `aria-label`, then `placeholder`. Field values are never read.
2. **Check the text before anything else.** `type_in_browser_field(tab_id, element_id, text)` first applies Halo's text policy (`ChromeBrowserService.textRefusal`), before any re-observation or prompt.
3. **Re-check the field.** `describeElementTarget(…, action: .type)` re-observes the tab and applies Halo's field policy (`isTypable`).
4. **Approve.** The preview shows:
   - the domain and page title
   - `Field: “<label>”`
   - `Text: <exact text>`
   - "Replaces any text already in the field. Nothing is submitted."
5. **Send.** A `typeText` request carries the text, bound to the approved generation and fingerprint.
6. **Type, inside the extension:**
   1. It re-checks the page and attaches `chrome.debugger` to that tab.
   2. The content script re-resolves the field, matches its fingerprint, re-applies the policy, and focuses and selects it.
   3. It confirms focus is still held and the page is unchanged.
   4. It sends `Input.insertText`, which generates trusted input events, inserts text only and never presses a key.
   5. It reports back only whether the field now equals the approved text.
   6. It always detaches.
7. **Report.** Halo matches the result to the request and returns `verified` to the model. The field's value is never sent to Halo, logged, or returned.

### 18.2 Field policy
| Typable | Refused before approval |
|---|---|
| `<input>` of type text, search, email, url, tel, number (or no type); `<textarea>`; enabled, editable, visible | password and protected fields; `autocomplete="one-time-code"` or `cc-*`; names, ids, or labels suggesting OTP, verification code, 2FA, CVV/CVC, card number, IBAN, SSN, PIN, or security code; `readonly`, disabled, `aria-disabled`; hidden or zero-size; anything else (checkboxes, selects, contenteditable) |

### 18.3 Text policy
Refused before approval:
- empty text
- more than 4,000 UTF-16 units
- any control character, including line breaks and tabs (it could press Enter and submit), and U+2028/U+2029
- text that looks like a secret:
  - private key headers
  - `sk-…`, `AKIA…`, `gh?_…` and `xox?-…` tokens
  - JWTs
  - a 40+ character mixed letter-and-digit token
  - 13–19 digit numbers passing the Luhn check (payment cards).

The protocol enforces the length and control-character rules again on the wire, and the extension checks them a third time.

*Trade-off:* the generic long-token rule can refuse a very long alphanumeric URL path. It is deliberately conservative.

### 18.4 Typing vs. submission
- Typing never submits: no Enter, no Tab, no submit, no key events at all.
- `Input.insertText` replaces the selection. Form submission belongs to 5B.4 and needs its own approval language.
- The live suite verifies that the fixture form's submission counter stays at 0 throughout.

### 18.5 Verification
| Check | Covers |
|---|---|
| `--check-browser-tabs` → "Phase 5B.2 text protocol and policy" | Unsafe text rejected on the wire; text on non-type requests rejected; the secret and card detector refuses its samples and allows ordinary text (URLs, order numbers, accented text, short digit groups). |
| `--check-browser-bridge-live` → 7 "5B.2" stages | The model-facing tool, with real approvals, against real Chromium. |

The 7 live stages:
1. the typable flags are correct
2. approved typing is genuine (`isTrusted`), verified without reading the field, and submits nothing
3. typing replaces the previous text, and textarea entry works
4. denial types nothing
5. five protected or ineligible fields and six unsafe texts are refused with no prompt
6. a field relabelled during approval is refused
7. a reload during approval is refused.

### 18.6 Limits
- **Loopback only** (development extension).
- **Main frame only.**
- **Not supported yet:** `contenteditable` editors, selects and checkboxes (5B.3).
- **Ordinary pasted secrets:** the detector is heuristic. It is a safety net, not a guarantee, and the approval preview showing the exact text is the primary control.

## 19. Phase 5B.3: Select, Scroll, and Navigation

Status: **complete** (2026-10-19). Each action is approved, re-verified against the live document, and checked afterward.

### 19.1 Select (`select_browser_option`)
- **Eligible:**
  - single-choice `<select>`, enabled, visible, not protected
  - not payment (`autocomplete="cc-*"`, expiry names) or credential-related.
- **What the model sees:** the observation lists up to 100 enabled option labels.
- **Before asking:** Halo checks that the requested option is one of them.
- **Approval:** `Dropdown: “<label>” / Option: “<option>”`, and "Nothing is submitted."
- **Mechanism:** the content script re-matches the fingerprint and re-applies the policy, finds the option by exact label, sets `selectedIndex`, and dispatches `input` and `change`.
  - This is the same approach as browser automation frameworks such as Playwright: native select popups cannot be driven reliably with input events.
  - The events are therefore untrusted. That is documented, not hidden.
- **Verification:** match/no-match on the selected option's label.

### 19.2 Scroll (`scroll_browser_tab`)
- **Targets:** the page, or one region marked `scrollable`. The observation reports up to 20 regions with `overflow` auto/scroll and overflowing content, named by `aria-label` or their first line of text.
- **Approval:** "Scroll the page / the region “…” <direction> by <n> steps" (1–20 steps of 120 CSS px).
- **Mechanism:**
  1. Attach `chrome.debugger`.
  2. The content script picks the point: the viewport centre for the page, or the region's centre for a region, after bringing it into view and checking that nothing covers it.
  3. Send a trusted `Input.dispatchMouseEvent` `mouseWheel`.
  4. Detach.
- **Verification:** the scroll position changed (polled briefly, since wheel scrolling is asynchronous).
- **Element references:** they stay valid, because scrolling does not change the document. Only the elements' positions change.

### 19.3 Navigation (`navigate_browser_tab`)
- **Address policy:** checked by Halo, by the protocol and by the extension.
  - absolute `http`/`https` only, with a host
  - no embedded username or password
  - no spaces or control characters
  - at most 2,048 bytes.
- **Approval:** the full `From:` and `To:` addresses. If the destination host differs, it adds "This leaves <domain>. Halo's access to this tab ends when the new site loads."
- **Mechanism:**
  1. `chrome.tabs.update`.
  2. The extension responds only after the new document has started loading, so the navigation event reaches Halo first.
  3. The validator accepts a navigation request's result across navigation events only. A pause, revoke or close in flight still invalidates it; other request types fail on any navigation.
- **After navigating:**
  - Halo drops the element cache. Old references cannot resolve: the new document has a new content script.
  - Same-site navigation keeps the authorization, following the record's URL.
  - Cross-site navigation ends it (domain-bound rule).
- **Exfiltration:** a hostile page could steer the model to put page data into an address. The tool description forbids building addresses from page content, and the approval always shows the complete destination.

### 19.4 Label correction
Form fields (`input`, `select`, `textarea`) are now named only by their associated `<label>`, `aria-label` or `placeholder`, never by their own text.
- Before this change, a `<select>`'s option list and a `<textarea>`'s content could appear as its label.
- That was a correctness bug, and a minor disclosure of field contents.

### 19.5 Verification
| Check | Covers |
|---|---|
| `--check-browser-tabs` → "Phase 5B.3 …" | Each action carries only its own fields; scroll bounds; unsafe and credentialed addresses rejected on the wire and by Halo's policy; navigation results survive only their own navigation (and not a pause in flight); other results fail on any navigation. |
| `--check-browser-bridge-live` → 8 "5B.3" stages | The model-facing tools, with real approvals, against real Chromium. |

The 8 live stages:
1. the dropdown and region flags are correct
2. an approved selection is verified and submits nothing
3. a disabled option and the multi-select, disabled and card-expiry dropdowns are refused, and denial changes nothing
4. a dropdown relabelled during approval is refused
5. a page scroll and then a region scroll both move, with a genuine wheel event
6. six unsafe addresses are refused with no prompt, and denial stays on the page
7. same-site navigation shows exact From/To, stays authorized, and old references fail
8. cross-site navigation warns and ends access.

### 19.6 Limits
- **Loopback only** (development extension).
- **Main frame only.**
- **Untrusted selection events:** select uses scripted events, which a page could in principle treat differently.
- **Native dialogs:** a page `beforeunload` dialog could block navigation. The extension times out after about 5 s and reports that the navigation did not start.
- **Not yet supported:** back, forward and reload.
