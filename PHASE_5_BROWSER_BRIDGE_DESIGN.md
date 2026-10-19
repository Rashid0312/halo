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
       "chrome-extension://knldjmfmopnpolahpmmgbagdohdnhkik/"
     ]
   }
   ```
   The absolute `path` is generated only during an explicit opt-in install and must be refreshed if the app moves. The browser launches a dedicated helper executable, not the GUI application binary.
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

### 16.1 Dedicated Helper Executable & Packaging
- **Target Name**: `HaloNativeHost` defined as an independent Swift executable target in `HaloNative/Package.swift`.
- **Packaged Path**: Placed alongside the main executable in `Halo.app/Contents/MacOS/HaloNativeHost`.
- **Development Path**: Built into `.build/release/HaloNativeHost` during build scripts and packaged into the bundle via `ditto`.
- **Packaging Script**: Updated in `HaloNative/scripts/build-app.sh` to compile, stage, and sign `HaloNativeHost`.

### 16.2 Code Signing & Identity
- **Signing Identity**: Signed using the same `$SIGN_IDENTITY` (`Mercy Local Signing` or configured identity) with `--timestamp=none`.
- **Designated Requirement**: Both `Halo.app` and `HaloNativeHost` share the same certificate leaf and team identity, satisfying the designated requirement verified by `check-signing.sh`.
- **Chromium Native Messaging Clarification**: Chromium does NOT verify the macOS code signature of native messaging helpers; it merely executes the binary path specified in the host manifest. Therefore, code signature verification and peer identity verification are performed strictly by Halo when the helper connects.

### 16.3 Development Extension Identity Strategy
- **Deterministic Extension ID**: Derived by Chromium from a fixed 2048-bit RSA public key embedded in the `"key"` field of `manifest.json`.
- **Pinned Origin**: Fixed extension ID `knldjmfmopnpolahpmmgbagdohdnhkik` (matches `chrome-extension://knldjmfmopnpolahpmmgbagdohdnhkik/`).
- **Origin Enforcement**: The native messaging host manifest specifies `allowed_origins: ["chrome-extension://knldjmfmopnpolahpmmgbagdohdnhkik/"]`. Chromium verifies this origin before launching the helper.

### 16.4 Chromium Browser for Fixture
- **Browser Executable**: `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` (Google Chrome 155).
- **Isolation**: Launched with `--user-data-dir=<disposable-temp-dir>`, `--no-first-run`, `--no-default-browser-check`, `--load-extension=<disposable-ext-dir>`, and the loopback fixture URL.

### 16.5 Manifest Installation & Removal
- **Manifest Path**: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/app.halo.browser_bridge.json`.
- **Lifecycle**: Installed dynamically by the test fixture and unlinked in a guaranteed `defer` block.
- **Contents**: JSON specifying host name `app.halo.browser_bridge`, absolute path to `HaloNativeHost`, `type: "stdio"`, and `allowed_origins`.

### 16.6 Extension Permission Strategy
- **Permissions**: Restricted to `["activeTab", "tabs"]` and host permission `["http://127.0.0.1/*", "http://localhost/*"]`.
- **Forbidden Permissions**: Zero `cookies`, `storage`, `history`, `downloads`, `webRequest`, `nativeMessaging` beyond the bridge, or broad `<all_urls>`.
- **Incognito Policy**: `"incognito": "not_allowed"`. Runtime checks in both background service worker and content script explicitly reject incognito tabs.

### 16.7 Authenticated Helper-to-Halo IPC Mechanism
- **Transport**: Ephemeral local Unix Domain Socket (`AF_UNIX`, `SOCK_STREAM`).
- **Socket Path**: Placed in an isolated user directory with mode `0700` (e.g. `~/Library/Application Support/Halo/bridge/bridge_<session>.sock` or `$TMPDIR/halo-bridge-<uid>/`).
- **Peer Identity Verification**:
  1. `getpeereid(fd, &euid, &egid)`: Asserts peer UID matches current effective UID (`geteuid()`).
  2. `getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &len)`: Retrieves connecting peer's PID from the macOS kernel.
  3. Peer binary verification: Checks `proc_pidpath(peerPID, ...)` to ensure the peer process binary is `HaloNativeHost` inside the signed bundle or build tree.
- **Per-Launch Freshness**:
  - Halo generates a cryptographically secure 32-byte random hex string (`sessionAuthToken`).
  - Stored in a mode `0600` file (`session_<session>.json`) in the private `0700` directory.
  - Upon connection, `HaloNativeHost` sends `sessionAuthToken` as the initial message.
  - Halo verifies `sessionAuthToken` using constant-time string comparison before processing any bridge requests.
- **No Background Listener**: The socket listener is activated only during an active browser session and terminated immediately upon completion or cancellation.

### 16.8 Cleanup & Rollback Behavior
- Every resource (native messaging manifest, extension files, temporary browser profiles, Unix domain sockets, session credential files, and child processes) is tracked and cleaned up in `defer` blocks.
- If a test times out or fails, `kill` is sent to both the browser and helper child processes, and all filesystem artifacts are removed.
