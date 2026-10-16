# Halo Native

Native SwiftUI/AppKit shell for macOS 26+ on Apple Silicon. Includes live DeepSeek conversation, tap-to-talk on-device Apple speech recognition, system-voice replies, and cancellation. Hands-free activation supports “Mercy” and “Hey Mercy”. Native app and file actions are available. ChatGPT sign-in, general window/UI control, and Calendar/Reminders integrations are not connected yet.

Build with the installed Command Line Tools (full Xcode is not required). The build currently reuses the pinned sherpa-onnx 1.13.8 native libraries under the legacy `node_modules` and the existing `models` directory. It copies them into the app bundle; no Node/Electron runtime is used:

```sh
cd HaloNative
bash scripts/build-app.sh
open build/Halo.app
```

Click the Halo menu bar icon to show/hide the panel. Type a message to stream a DeepSeek reply. Recent conversation is included for follow-up questions. Stop or Escape cancels the reply; sending another message supersedes it. Tap the microphone to start speaking, then tap it again to send. The first attempt requests microphone permission and may download Apple’s English speech model. Listening ends after 30 seconds at most. Stop/Escape cancels listening, generation, and playback. Use Settings → Speak replies to mute the system voice; this preference is saved. Use the panel menu for Settings, Clear, or Quit.

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
