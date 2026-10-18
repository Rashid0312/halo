# Halo Native

Native SwiftUI/AppKit shell for macOS 26+ on Apple Silicon. Includes live DeepSeek conversation, tap-to-talk on-device Apple speech recognition, system-voice replies, and cancellation. Hands-free activation supports “Mercy” and “Hey Mercy”. Native app and file actions are available. Native Accessibility-based UI and window controls are available. ChatGPT sign-in, screenshot understanding, and Calendar/Reminders-specific integrations are not connected yet.

Build with the installed Command Line Tools (full Xcode is not required). The build currently reuses the pinned sherpa-onnx 1.13.8 native libraries under the legacy `node_modules` and the existing `models` directory. It copies them into the app bundle; no Node/Electron runtime is used:

```sh
cd HaloNative
bash scripts/build-app.sh
open build/Halo.app
```

Click the Halo menu bar icon to show/hide the panel. Type a message to stream a DeepSeek reply. Recent conversation is included for follow-up questions. A collapsible activity timeline shows whether Halo is contacting the model, searching and reading sources, executing a Mac tool, waiting for approval, or writing the answer; long stalls expose Stop and Retry instead of appearing frozen. Stop or Escape cancels the reply, tools, network work, and speech. Tap the microphone to start speaking, then tap it again to send. Apple SpeechAnalyzer performs recognition on this Mac. Deepgram Aura 2 streams spoken replies sentence-by-sentence, with the Mac voice as a failure fallback. Use Settings → Voice to mute spoken replies.

```sh
swift run HaloCoreChecks
```

The app uses bundle ID `app.halo.native.dev` with its own Keychain service. On first launch the development build imports only `DEEPSEEK_API_KEY` from the existing project `.env` (or launch environment), without displaying it. The key is never bundled. Subsequent launches use Keychain; the Electron profile is unchanged. Conversation is held in memory only. The local build is ad-hoc signed, not a distributable notarized release. An Xcode project and release signing are later packaging work.

See [the migration plan](../SWIFT_PLAN.md).

The current development bundle records the project `.env` path for first-run credential import. Release packaging must omit this development-only setting. Requests follow the [DeepSeek streaming API](https://api-docs.deepseek.com/api/create-chat-completion/).

Voice validation: the bundled executable accepts `--check-speech-file /path/to/sample.wav` to exercise native audio conversion and finalization without microphone recording. The development check expects the sample to contain “Mercy”. When hands-free is enabled, the microphone stays open for local keyword detection. A bounded two-second pre-roll preserves the start of requests. Apple transcription must also confirm the wake phrase before the remaining request is sent to DeepSeek. The wake detector pauses during model responses and spoken playback, then resumes after a short echo guard. Automatic endpoint detection uses local Silero VAD. A visible toggle turns hands-free off and stops that capture. Speaker enrollment is not implemented in this native version. Spoken playback currently starts after the complete answer arrives. A three-second live microphone capture/finalization check passes. Bluetooth, sleep/resume, extended use, and echo behavior still require validation.

Crash regression: `build/Halo.app/Contents/MacOS/Halo --check-audio-callback` runs the actual tap callback off the main actor using synthetic audio. `--check-microphone` captures three seconds locally and finalizes without sending or logging the transcript. Audio callbacks must be created outside MainActor-isolated code; creating the tap closure inside the UI controller previously caused a dispatch isolation assertion.

Wake validation: `--check-wake-file sample.wav` checks keyword detection (`--expect-no-wake` reverses the expectation). `--check-handsfree-file sample.wav` checks detection, pre-roll, local transcription, automatic endpointing, and wake-phrase removal without any cloud call. Inputs must be 16 kHz mono WAV. Both wake phrases pass synthetic positive tests and an unrelated sentence passes a negative test; these are smoke checks rather than a measured real-world false-trigger rate. `--check-wake-microphone` exercises three seconds of live wake capture locally. Hands-free is enabled by default for this development version and can be disabled in the panel or Settings.

Native notices are bundled in `Contents/Resources`: sherpa-onnx and its keyword model (Apache-2.0), ONNX Runtime (MIT), and Silero VAD (MIT). The public C header is vendored from sherpa-onnx v1.13.8; the bridge rejects another runtime version rather than risking an ABI mismatch. Packaging stages signing outside the Desktop sync directory to avoid file-provider metadata breaking code signing.

App-aware speech and native access:

- Halo indexes installed application bundles in Applications, system app locations, and the user’s Applications directory. It stores real names, bundle IDs, and paths. Refresh in Settings after installing or moving an app.
- Installed names feed Apple SpeechAnalyzer’s vocabulary. Known variants such as “streamio” and the observed transcription “Streamo” resolve to the installed Stremio app. They do not create a match when Stremio is absent. Ambiguous/fuzzy matches show actual installed apps; selecting one can save that spoken correction. Custom spoken names can be managed in Settings.
- Simple app launches route locally through NSWorkspace without a model round trip. Compound requests can use DeepSeek’s native tool loop: list_apps, running_apps, open_app, list_files, read_file, open_path, write_file.
- File tools respect the Mac account’s permissions. Folder listings return up to 200 entries; reads accept regular UTF-8 text files up to 32 KB. Files actually read for an AI request are included in that provider’s context. Background microphone audio is never included.
- Writes up to 64 KB show their actual resolved path and complete proposed content. Each write requires approval. Denial or cancellation prevents it; successful writes are atomic. Special files/devices cannot be read or overwritten through these text tools.
- Protected locations may need macOS Full Disk Access. Settings provides a button to that pane and a button revealing the running Halo.app. The user must grant the OS permission. Granting a permission does not add unsupported features or bypass macOS protection.

Checks: `--check-app-catalog` verifies the real installed Stremio alias; `--check-open-app streamio` actually launches it; `--check-app-voice-file sample.wav` verifies local wake/transcription/app resolution; `--check-native-files` uses disposable temporary fixtures to verify reads and write approval/denial/cancellation. `--check-model-tools` makes a small live DeepSeek request and verifies that it actually calls the native app-list tool.

General Mac interface controls:

- `inspect_ui` reads a running app’s real Accessibility tree on a separate actor, with bounded depth, node count, text size, and messaging timeouts. `root_id` drills into an observed subtree. Every inspection invalidates the previous control IDs. UI contents are untrusted data; protected text-field values are omitted.
- `ui_action` performs an action actually exposed by the observed control. `type_text` focuses a specific observed text field and checks that focus before posting Unicode input to that process. `keypress` sends a validated shortcut to a named running app. These generic actions require a preview/approval and check cancellation before execution. Results distinguish accepted input from verified outcomes; the model is instructed to inspect again afterward.
- `window_layout` arranges or minimizes an app’s focused window, including placement on another connected display. It accounts for the menu bar/Dock work area and the Accessibility coordinate system. Full-screen Spaces and app-enforced minimum sizes remain limitations. `screen_info` lists connected displays without capturing pixels.
- Enable native interface access with Settings → Mac Access → Enable Mac controls. macOS must authorize Halo. The app remembers the external app used before its panel activated, so “this app” does not accidentally target Halo. Incomplete Accessibility trees fall back to a user-reviewed, app-scoped screenshot. Secure authentication and protected OS dialogs may require the user.
- Current-information requests can use bounded `search_web` and `read_web_page` tools. Local/private addresses, oversized downloads, unsupported content, and slow sites are rejected. Opening a browser is presentation only, not evidence.
- The model can perform up to twelve tool rounds per request. Stop cancels pending actions/approvals; it cannot undo input or external actions that already completed.

Validation: `--check-ui-controls` checks definitions, shortcuts, stale-reference rejection and reports OS access; `--check-ui-inspect com.apple.finder` reads real controls without printing contents. `--check-ui-interaction` starts a separate disposable host app and verifies cross-process inspection, button action, multi-chunk Unicode typing, a keyboard shortcut, window movement and stale-ID invalidation. It does not edit user documents. The host is separate because self-targeted AX calls can directly invoke AppKit on the caller’s thread, which is unsafe for Swift MainActor UI callbacks.

Native app/web tools: `open_url` hands HTTP(S) links to the default browser; `quit_app` requests normal termination by a running app’s bundle ID, preserves unsaved-work prompts, and reports pending termination without force quitting. Neither requires Accessibility access.

General execution: `run_shell` executes zsh commands and `run_applescript` controls scriptable apps after the exact source and explanation are approved. Both run off the UI actor with a 60-second deadline, capped stdout/stderr (32 KB each), no interactive stdin, and cancellation of the launched process. Credentials from Halo’s environment are not inherited. Completed actions cannot be undone, and independently detached subprocesses may survive cancellation. `--check-commands` verifies output, failure, output limits, timeout, running cancellation, approval denial/acceptance, and cancellation before script approval. Screen understanding is provided separately by inspect_screen; command execution itself does not add visual perception.

`inspect_screen` captures a chosen app window or display (excluding Halo for display capture), shows the exact image, and only shares it with DeepSeek after approval. Images remain in memory for the current tool loop, not in chat history or screenshot files. `--check-screen` verifies a disposable window containing a synthetic visual code; it does not share your desktop.

Build signing: the script uses `HALO_SIGN_IDENTITY`, an ignored `.native/signing-identity.txt` override, or the existing trusted `Mercy Local Signing` identity. Otherwise it warns and signs ad-hoc. `bash scripts/check-signing.sh` checks that two different executables satisfy Halo's certificate-based designated requirement. Stable signing addresses rebuild identity changes; switching from an old ad-hoc build can still require a one-time permission refresh.

### Panel appearance

Halo now opens from its menu-bar icon as a slim native Liquid Glass panel that slides in from the right edge below the menu bar. In the default mode, retracting, Escape, or clicking another app slides it out completely. The header pin or Settings → Appearance → Keep in corner saves a persistent corner mode: click-away leaves the panel visible, and retracting shrinks it to a small glass capsule. Drafts survive retraction. Approval previews stay open until resolved. macOS controls menu-bar item ordering; Command-drag Halo's icon to place it beside Siri. Reduced Motion disables the window slide.

### ChatGPT connection

Settings → Brain → Continue with ChatGPT ports Mercy's documented browser/PKCE sign-in to native Swift. Tokens are validated against OpenAI's JWKS and stored in Halo's Keychain entry; refreshes are serialized. Halo obtains the account's model catalog and streams Responses API requests (`store: false`, low reasoning), including native tools and approved screenshots. Successful sign-in selects ChatGPT automatically; DeepSeek remains selectable. The Electron-encrypted Mercy session is not imported; complete one new Halo browser authorization. Source: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
