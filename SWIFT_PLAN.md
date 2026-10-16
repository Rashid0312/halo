# Native Halo migration plan

Status: implementation started. Native shell, DeepSeek streaming, structured recent conversation, existing development-key import into separate Keychain storage, and offline cancellation/parser checks are implemented in `HaloNative/`. Tap-to-talk AVAudioEngine capture, Apple SpeechAnalyzer transcription, system-voice replies, and synthetic-file speech validation are also implemented. Native sherpa-onnx wake detection for “Mercy” and “Hey Mercy”, local VAD endpointing, shared capture with pre-roll, a hands-free toggle, and full synthetic voice-path checks are implemented. Installed-app indexing, speech vocabulary, spoken-name aliases, native app launching, model tool calls, and native folder/text-file access with write approval are implemented. Other Mac integrations, speaker enrollment, and ChatGPT sign-in remain pending; extended microphone-route and recovery checks are not yet complete.

## Goal and boundaries

Build a standalone Swift/SwiftUI Mac assistant with native audio capture, a floating panel, streaming conversation, and native Mac actions. Improve measured responsiveness and hearing reliability rather than assuming a language rewrite will improve recognition.

- Work on `swift/halo`. `legacy/electron` preserves the existing Electron implementation at commit `21fec40`; `main` was left unchanged.
- Start with Apple Silicon and macOS 26+, matching the existing SpeechAnalyzer integration. Revisit older macOS support after the first native release.
- Keep the existing Electron files as reference during development. Native Halo must eventually launch without Electron, Node, or a background JavaScript service.
- Give native Halo its own bundle identifier, preferences, Keychain entries, and application-support directory. Do not overwrite the legacy profile or automatically install competing Claude hooks/login items.
- Preserve the compact orb/panel identity. Build functionality before visual polish.
- Retain targeted Apple events/AppleScript where no suitable public API exists. No private-framework dependency in the core app.

## Architecture

One native application initially; introduce helper processes only for a demonstrated isolation or lifecycle need.

```text
SwiftUI views + AppKit panel/menu bar
                 |
       Conversation coordinator
       /          |            \
Audio pipeline  Model client  Permission/action executor
       |          |            |
STT / wake / TTS  Providers    macOS frameworks + fallbacks
```

- SwiftUI for views; AppKit for floating panels, focus, menu bar, and Spaces behavior.
- A single explicit conversation state machine: idle, listening, transcribing, thinking, awaiting approval, executing, speaking, and recovering.
- Swift concurrency for streaming and cancellation. UI updates on the main actor; audio callbacks never wait on networking, model inference, disk writes, or UI work.
- Typed requests/results and provider protocols. Carry request IDs through audio, model, approval, execution, and playback so superseded work cannot update a newer turn.
- Keychain for credentials; versioned, atomic settings storage. Normal logs contain timings, action names, and errors with sensitive content redacted.
- An Xcode app target for packaging, permissions, signing, and resources, with a local Swift package for testable core logic. Keep initial modules small rather than splitting every service into a package.

Suggested eventual layout:

```text
HaloNative/
  Halo.xcodeproj
  Halo/                 # app entry, SwiftUI views, AppKit window integration
  HaloCore/
    Package.swift
    Sources/            # conversation, audio, providers, actions, persistence
    Tests/
  Resources/            # assets and model manifest
```

## Milestone 0 — Baseline and build foundation

1. Record legacy feature behavior and stage timings: end of speech, final transcript, model first token, action start/end, and first audible reply.
2. Use a fixed set of consented speech samples and commands, including background noise, names, interruptions, and short follow-ups. Keep private samples out of Git.
3. Verify Xcode/SDK availability and establish a reproducible native app build. Current environment has Swift 6.2.3; `xcodebuild` reports that the selected developer directory is Command Line Tools rather than full Xcode. The initial shell uses Swift Package Manager plus an app-bundle script; an Xcode project is deferred until full Xcode is available.
4. Create native app identity and separate development data. Add fake model/audio/action implementations for development without cloud calls or real side effects.

Done when: a native app bundle builds and launches, its profile is isolated, and a baseline report defines what we will compare. Set numeric performance targets from that baseline, not guesses.

## Milestone 1 — Working typed assistant

1. Add the menu bar icon, floating conversation panel, text input, settings, and visible states.
2. Port one model provider first: DeepSeek streaming through URLSession, including tool-call assembly, errors, and cancellation.
3. Preserve structured conversation/tool history; bound it by a token budget.
4. Make Stop cancel pending network work and prevent stale output. Show offline, authentication, rate-limit, and tool-limit failures with a useful next action.

Done when: type a request, see a streamed answer, stop it, and ask again without stale tokens or UI blocking. No Electron process is needed.

## Milestone 2 — Hearing and spoken replies

1. Capture microphone audio using AVAudioEngine, with explicit format conversion and bounded in-memory buffers.
2. Adapt `native/speech/MercySpeech.swift` into a reusable Swift service rather than launching it as a subprocess. Preserve its transcript finalization and vocabulary-hint behavior.
3. Implement push-to-talk first, with partial transcripts, endpoint detection, no-speech timeout, and model-download/permission states.
4. Add Deepgram STT as an explicit alternative. Never silently send audio to the cloud when the user selected on-device-only recognition.
5. Add streamed Deepgram speech playback; provide a system-voice option. Keep playback under the same turn cancellation lifecycle.
6. Evaluate AVAudioEngine voice processing on supported input/output routes. Test speaker echo, headphones, Bluetooth changes, and actual interruption behavior rather than assuming echo cancellation solves every route.
7. Recover cleanly from sleep, microphone changes, unplugged devices, and lost network connections.

Done when: the full push-to-talk loop works; Stop halts playback; interruptions do not duplicate requests; repeated turns and device changes remain stable. Compare transcript accuracy and stage latency with the legacy baseline.

## Milestone 3 — Native actions and approvals

1. Build a typed action registry and permission gate before enabling writes.
2. Implement app activation/opening and URLs using NSWorkspace, and normal app termination using NSRunningApplication.
3. Implement window positioning using Accessibility APIs, with display coordinates, multiple monitors, and unsupported/full-screen cases handled explicitly.
4. Implement Calendar/Reminders through EventKit and contact lookup through Contacts. Request the corresponding macOS permissions with clear recovery states.
5. Add a narrow local command router for unambiguous commands such as opening a known app. Ambiguous requests go to the model or clarification; do not guess recipients or destructive actions.
6. Retain Notes, Messages, Shortcuts, and terminal integrations as explicit adapters where required. Preserve exact recipient/message previews and existing trust choices intentionally.
7. For arbitrary shell/scripts, use conservative approval rules rather than treating regex matching as a security boundary. Propagate cancellation into processes; prevent new side effects after cancellation. Explain that already-completed external actions cannot be undone by Stop.

Done when: representative actions return verified success/failure, approvals are tied to the exact action, denied/cancelled actions never start, and eligible native actions launch no `osascript` process.

## Milestone 4 — Hands-free listening

1. Prove sherpa-onnx integration through its supported native/Swift interface for keyword spotting, voice activity detection, and speaker embeddings before committing to its packaging approach.
2. Port wake-word enrollment, speaker matching, follow-up windows, and false-trigger protection from `main/wake.js` and `main/voiceprint.js`.
3. Validate a Halo wake phrase independently: the current enrollment prompts and tuning use Mercy. Renaming the UI does not retune the wake model.
4. Keep wake detection and speaker matching local; bound the pre-roll buffer and make microphone state visible.
5. Test detection during playback, in noisy rooms, and across intended microphones. Speaker matching remains a convenience filter, not authentication.

Done when: measured false accepts/rejects, missed first words, idle CPU/energy use, and interruption behavior are acceptable against the baseline. Preserve an obvious push-to-talk fallback.

## Milestone 5 — Feature parity and release

1. Port screen assistance with native capture and explicit Screen Recording permission handling. Avoid capturing Halo's own overlay where supported; verify exclusion behavior on the target OS.
2. Port additional model/auth providers, including the existing ChatGPT integration only after checking its supported authentication and service contract. Do not assume copying tokens or Electron-encrypted files is valid.
3. Port Claude session visibility, local authenticated bridge, approvals, narration, and terminal relay. Make hook ownership explicit so the two versions do not compete.
4. Add login-item management, update delivery, onboarding, accessibility/keyboard navigation, and settings export/import where useful.
5. Treat Touch Bar integration as optional; the legacy implementation relies on private API and must not block the native release.
6. Package model/native libraries with license notices; complete signing/notarization and validate on a clean machine.
7. Offer an explicit migration path for compatible preferences; reauthenticate and re-enroll when necessary. Keep the legacy app/profile available for rollback.

Done when: the feature checklist is reviewed, the release runs without Node/Electron, permissions work from the installed bundle, and installation/update/recovery are verified.

## Validation throughout

- Offline tests for state transitions, interrupted streams, transcript finalization, tool validation, approval denial/timeout, settings migrations, and cancellation races.
- Integration tests with fake transports/actions; real app writes only in deliberate manual checks using disposable data.
- Compare the same speech corpus, hardware, locale, and provider settings. Report word error rate, wake false accepts/rejects, median/p95 stage latency, idle memory/CPU, and wake energy impact.
- Never claim improved hearing or speed from successful compilation alone.

## First implementation task

Complete milestone 0 and build the milestone 1 native shell: isolated Halo identity, menu bar icon, floating text panel, fake streamed response, and working Stop. Then connect DeepSeek. Do not begin with a wholesale port or delete the reference implementation.

## Technical references

- Apple SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer
- Apple voice processing: https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
- Apple Accessibility: https://developer.apple.com/documentation/applicationservices/axuielement_h
- Apple EventKit: https://developer.apple.com/documentation/eventkit/creating-events-and-reminders
- sherpa-onnx Swift examples: https://k2-fsa.github.io/sherpa/onnx/swift-api/examples.html
