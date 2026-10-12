# Mercy

A friendly AI sidekick for your Mac. Say **"Hey Mercy"** (or type), and she answers out loud, sees your screen, and can act on your Mac — opening apps, calendar, reminders, notes, messages, shortcuts, terminal commands — always asking before anything risky.

## Install (Apple Silicon Mac)

1. Download **Mercy-x.y.z-arm64.dmg** from [Releases](https://github.com/Rashid0312/mercy/releases) and drag **Mercy** into **Applications**.
2. Open Mercy. macOS will say it can't verify the developer (Mercy isn't signed with a paid Apple Developer ID yet): open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   Or in Terminal: `xattr -dr com.apple.quarantine /Applications/Mercy.app`
3. Mercy appears as a ring in the menu bar (no Dock icon). Click it and **Connect Mercy** with your own keys:
   - Deepgram (voice): <https://console.deepgram.com/>
   - DeepSeek (brain): <https://platform.deepseek.com/api_keys>
4. **Teach Mercy your voice**: say "Hey Mercy" five times and read three short sentences.
5. Allow the microphone (and later Calendar, Reminders, Notes, Messages… when Mercy first uses them).

Mercy starts at login (turn it off in ··· → Open at login). Updates: Mercy tells you when a new version is out — download it and replace the old one. After an update macOS may ask for the microphone permission again.

## Build from source

```sh
npm install
npm run models        # on-device wake word + voice recognition models (~44 MB)
cp .env.example .env  # optional: DEEPGRAM_API_KEY / DEEPSEEK_API_KEY for development
npm start
npm run dist          # builds dist/Mercy-<version>-arm64.dmg
```

## Using it

- **"Hey Mercy, …"** — only your voice wakes her. After she answers you have ~6 s to follow up without the wake word.
- **Type** in the panel, or tap 🎤.
- Click the menu bar ring or the pill for the panel: tiles for "Hey Mercy", Speak replies, Look at my screen, My voice (re-train), and ··· (open at login, API keys, logs, delete voice, quit).
- **Touch Bar:** Mercy's ◉ button sits in the Control Strip (remove Siri's in System Settings → Keyboard → Touch Bar Settings → Customize Control Strip). Tap to talk, tap again to send. It uses private macOS API, so a future macOS update could break it.

## Privacy

- The wake word and voice check run **on your Mac** (sherpa-onnx). Mic audio lives in a 2–3 s memory buffer and is never written to disk.
- Nothing is sent to Deepgram until "Hey Mercy" (or a follow-up) has matched your voice locally.
- Your voice profile is encrypted with the macOS Keychain (`voiceprint.bin` in Mercy's app data) and never uploaded. ⚙ → *Delete my voice* removes it.
- Voice matching keeps strangers out but isn't a security lock — a recording of you could fool it. Risky actions always show an approval card.

## Development

- `npm run eval` — tool routing, multi-turn and voice latency checks (calls DeepSeek/Deepgram).
- `MERCY_DEBUG=1` — verbose logs. `MERCY_USER_DATA=/tmp/x` — use a throwaway profile.
- `MERCY_FAKE_MIC=file.pcm` (16 kHz mono s16le) plays a file as the microphone; `MERCY_FAKE_WAKE_AT="2.9,37"` simulates the wake word at those times.

## Credits

On-device models, downloaded by `npm run models`:

- Keyword spotter: [sherpa-onnx-kws-zipformer-gigaspeech-3.3M](https://github.com/k2-fsa/sherpa-onnx) — Apache-2.0
- Speaker embeddings: [NVIDIA TitaNet-small](https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/titanet_small) (ONNX export by sherpa-onnx) — [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/)
- Voice activity detection: [Silero VAD](https://github.com/snakers4/silero-vad) — MIT
- Runtime: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) — Apache-2.0
