# Native Halo verification — 2026-10-16

## Passed

- Release app build and signed-bundle verification.
- Stable signing: the app uses the existing Mercy Local Signing identity. Two disposable executables with distinct code hashes satisfy the app's certificate-based designated requirement. The unused, untrusted identity created during setup was removed; existing certificate trust was not changed.
- Core cancellation, late-output rejection, streaming parser, tool-call assembly, installed-app resolution/aliases, and wake endpoint checks.
- Conversation rendering is backpressured to a 50 ms cadence. Burst-stream regression coverage verifies 1,000 provider fragments are coalesced into fewer than ten UI mutations; input, reply, row-count, and total retained-text limits are enforced.
- Image attachments: screenshot bytes become image content rather than base64 tool text; declined and unsupported image results do not produce attachments.
- Cross-process disposable app: observed Accessibility button action, Unicode typing, targeted keyboard shortcut, window movement, entering full screen, automatic full-screen exit and placement, stale-control rejection.
- Native screen capture of a disposable test window, JPEG encoding, live DeepSeek image attachment/tool loop, and reading the synthetic five-digit code from the image. No desktop image was sent for this check.
- Native files: list/read, exact write preview, denial, approval, cancellation, special-file rejection. Separately, the actual Halo chat/approval UI wrote a disposable two-line Unicode file and read it back; contents were independently verified (canonical-equivalent Unicode).
- Shell execution output, nonzero exit/stderr, actual AppleScript interpreter execution, 32 KB output bounds, timeout, running cancellation, exact approval, denial, pending script cancellation.
- Native opening and normal quitting of Dictionary, only when it was not already open. No force quit.
- Negative synthetic wake sample rejected.
- Wake phrase + two-second pause + request: complete buffered speech/endpoint/transcription path passes.
- Continuous synthetic speech transcription.
- Live three-second microphone capture/finalization and hands-free microphone start/stop; no transcript logging or cloud audio.

## Implemented, with physical/manual validation remaining

- Audio engine configuration-change recovery and sleep/wake recovery. These handlers cancel the interrupted voice turn and rebuild hands-free capture according to the saved preference. Actual Bluetooth unplug/reconnect and sleep/wake transitions have not been exercised.
- Multi-display placement and application-specific minimum window sizes.
- Unsaved-document quit prompts (the app never force quits).
- Accuracy with the user's natural voice, background noise, and different microphones. Synthetic samples and capture checks do not establish real-world recognition quality.

## Important permission distinction

Command-line test processes may inherit their launcher's access. Their success does not prove that the launched Halo app has equivalent grants. The actual GUI process was checked and reported Accessibility and Screen Recording unavailable after ad-hoc rebuilds. Stable signing is now configured. The certificate-signed GUI process was relaunched and still reports both grants unavailable. A one-time permission refresh is required before validating live screen previews and UI control in the GUI process. This remains separate from functional test results.

## Scope

Generic UI controls, screenshots, command execution, and AppleScript fallback are available. This does not mean every Mac workflow is verified. Dedicated Calendar/Reminders/Contacts adapters, speaker enrollment, and ChatGPT sign-in remain on the migration plan. Arbitrary commands and scripts require their exact preview; completed actions cannot be undone and detached subprocesses can outlive the launched parent.
