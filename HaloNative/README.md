# Halo Native

Native SwiftUI/AppKit shell for macOS 26+ on Apple Silicon. Includes live DeepSeek conversation and streaming cancellation. Microphone, Mac actions, and ChatGPT sign-in are not connected yet.

Build the app using the installed Command Line Tools (full Xcode is not required for this initial shell):

```sh
cd HaloNative
bash scripts/build-app.sh
open build/Halo.app
```

Click the Halo menu bar icon to show/hide the panel. Type a message to stream a DeepSeek reply. Recent conversation is included for follow-up questions. Stop or Escape cancels the reply; sending another message supersedes it. Use the panel menu for Settings, Clear, or Quit.

```sh
swift run HaloCoreChecks
```

The app uses bundle ID `app.halo.native.dev` with its own Keychain service. On first launch the development build imports only `DEEPSEEK_API_KEY` from the existing project `.env` (or launch environment), without displaying it. The key is never bundled. Subsequent launches use Keychain; the Electron profile is unchanged. Conversation is held in memory only. The local build is ad-hoc signed, not a distributable notarized release. An Xcode project and release signing are later packaging work.

See [the migration plan](../SWIFT_PLAN.md).

The current development bundle records the project `.env` path for first-run credential import. Release packaging must omit this development-only setting. Requests follow the [DeepSeek streaming API](https://api-docs.deepseek.com/api/create-chat-completion/).
