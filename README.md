# Siri+

[![Support on Boosty](https://img.shields.io/badge/Boosty-support-F15F2C?logo=boosty&logoColor=white)](https://boosty.to/rtm00)
[![Latest release](https://img.shields.io/github/v/release/rtmo0/siri-plus)](https://github.com/rtmo0/siri-plus/releases/latest)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)

A personal assistant for macOS 26 that lives in the menu bar. During a call in Zoom, Teams, Telegram, a browser or any other app, it listens, recognizes speech right on your Mac and suggests what to say about the topic being discussed. Outside calls, ⌃⌥Space opens a Siri-style panel: ask by voice or text, attach a file, get an answer.

The interface is in English and Russian and follows the system language. Swift 6, SwiftUI, Liquid Glass, no third-party dependencies.

## How it works

![How Siri+ works: call audio, microphone, voice and files are processed on the Mac; only text goes to Claude or ChatGPT, which return hints, answers and meeting summaries](docs/how-it-works.svg)

## What it can do

| | Feature | Runs |
| :-: | --- | --- |
| ✅ | Lives in the menu bar, no Dock icon | Mac |
| ✅ | Listens to any call: Zoom, Teams, FaceTime, Telegram, Telemost, Slack, Discord, a browser, or all system audio | Mac |
| ✅ | Keeps “Me” (microphone) and “Them” (call audio) apart in the transcript | Mac |
| ✅ | On-device speech recognition in English, Russian and other macOS languages, with automatic language choice | Mac |
| ✅ | Spots questions in the conversation and suggests answers in a side panel | Mac + model |
| ✅ | Hint panel hidden from screen sharing | Mac |
| ✅ | Offers to start listening when a call begins and to stop when it ends | Mac |
| ✅ | Meeting materials (agenda, names, terms) help recognition and hints | Mac + model |
| ✅ | Meeting history: title, summary, action items with checkboxes, participants, full transcript | Mac + model |
| ✅ | Ask questions about a past meeting, export it to Markdown | Mac + model |
| ✅ | Siri-style ask panel on ⌃⌥Space with voice dictation | Mac + model |
| ✅ | Chat with saved history and search | Mac + model |
| ✅ | Attach images, PDFs, text and code files | Mac + model |
| ✅ | Transcribe audio and video files (MP3, M4A, WAV, AIFF, MP4, MOV…) | Mac |
| ✅ | Claude: browser sign-in through Claude Code, or an API key | model |
| ✅ | ChatGPT: browser sign-in to your account, or an API key | model |
| ✅ | Subscription limits: how much is left and when it resets | Mac |
| ✅ | Desktop widget and a Shortcuts action | Mac |
| ✅ | Updates itself from GitHub releases | Mac |

## Install

Download `SiriPlus-<version>-arm64.dmg` from [Releases](https://github.com/rtmo0/siri-plus/releases) (Apple silicon, macOS 26 or later).

Siri+ is not signed with an Apple Developer ID, so macOS blocks the downloaded copy. Either:

- open the disk image, right-click `Install Siri+.command` → Open → Open. It copies the app to Applications and removes the quarantine flag;
- or drag `SiriPlus.app` to Applications and run:

```sh
xattr -dr com.apple.quarantine /Applications/SiriPlus.app
```

First launch:

1. The ✦ icon appears in the menu bar.
2. Settings → Model: choose Claude or ChatGPT and sign in.
3. Meeting → Start. macOS asks for screen and system audio recording and for the microphone.

## Meetings

- **Audio source.** A running call app is picked automatically. You can choose any other running app (for example a browser with Google Meet) or “All system audio”, which works with any call.
- **Your voice** comes from the microphone as a separate channel, through macOS voice processing: echo cancellation subtracts what the speakers play. “Me” lines that nearly repeat the other side from the last 10 seconds are dropped as echo. Headphones are still the most reliable.
- **Language.** “System” listens for your system languages and keyboard layouts at once. For each speaker, the language whose recognizer is clearly more confident over the first phrases is kept and the others stop. You can also fix the language in Settings.
- **Hints** come after a question from the other side and about every 45 seconds while the conversation moves on, only on questions, or only on request (the Hint button or ⌃⌥Space). The model answers “—” when no hint is needed, and nothing is shown.
- **Questions** are spotted locally by question words after a short pause, since on-device Russian recognition adds no punctuation.
- **History.** After Stop, the meeting is saved on your Mac with a title, summary, action items and participants written by the model. The search covers everything, including the transcript. “Ask about meeting” opens a chat that answers from the transcript.

Tell participants you use an assistant: recording a conversation without consent is illegal in many countries.

## Chat and the ask panel

- **⌃⌥Space** in any app opens a translucent panel that starts listening right away. Speak a command; it is sent when you fall silent for 1.5 seconds. Press again to send at once.
- The panel sits in the top-right corner with the same margin as widgets. Drag it by any empty area; the place is remembered.
- Attach files with the paperclip or drag and drop. Images go to the model as images; PDF, text and code are read on the Mac; audio and video are transcribed on the Mac and only the transcript is sent. Telegram voice notes (OGG/Opus) need converting first.
- The input grows up to 13 lines, then scrolls. Return sends, Shift-Return adds a line.

## Models and sign-in

| Provider | Browser sign-in (default) | API key |
| --- | --- | --- |
| **Claude** | Through the official [Claude Code](https://code.claude.com/docs/en/setup): “Sign in to Claude” opens Terminal with `claude auth login`. Requests run through `claude -p` in safe mode (no tools, no saved sessions) and use your Pro/Max limits. | A key from [Claude Console](https://platform.claude.com/settings/keys); direct streaming requests to `api.anthropic.com`. |
| **ChatGPT** | OAuth sign-in to your ChatGPT account (PKCE, loopback on port 1455/1457), as in Codex. Tokens live in the Keychain and refresh automatically. | An OpenAI API key, Responses API. |

Claude models: Opus 5.5, Sonnet 5.5 or Haiku 5.5. Haiku is the fastest for meeting hints (the answer starts in about two seconds).

With an account sign-in, Siri+ shows what is left of your subscription limits and when they reset: in Settings, in the sidebar status line and in the menu bar menu. Claude limits come from `claude -p /usage`, ChatGPT limits from the account's usage endpoint. API keys have no subscription limits.

Subscription sign-in is for personal use on your own Mac.

## Privacy

| On your Mac | In the cloud (Claude or ChatGPT) |
| --- | --- |
| Capturing call and microphone audio | Meeting hints |
| Speech recognition | Answers in chat and the ask panel |
| Spotting questions | Reading an attached screenshot or image |
| Sign-in tokens and API keys (Keychain) | Meeting title, participants and summary after Stop |
| Chats and meeting history (`~/Library/Application Support/SiriPlus/`) | |

Audio is never sent anywhere. The model receives your messages, attachments, and a recent piece of the transcript (up to about 6,000 characters) with the meeting materials when a hint is needed. After Stop, the transcript is sent once more to write the summary.

## Updates

Siri+ checks the [latest release](https://github.com/rtmo0/siri-plus/releases/latest) 10 seconds after launch and every 12 hours, or on demand from the menu. When a new version is out, it offers to install it: downloads the DMG with a progress bar, verifies its SHA-256, checks the version inside, replaces the app and relaunches. The app needs to live in a folder you can write to, such as Applications.

## Build from source

Requires Xcode 26 and macOS 26.

```sh
bash scripts/build.sh
open build/Build/Products/Debug/SiriPlus.app
```

macOS remembers microphone and screen recording permissions by the app's signature. An ad-hoc signature changes with every build, so permissions would reset each time. Create a stable self-signed certificate once and every build is signed with it:

```sh
bash scripts/make-signing-identity.sh
```

For GitHub releases, add the repository secrets `SIRIPLUS_SIGNING_P12` (the base64 printed by the script) and `SIRIPLUS_SIGNING_P12_PASSWORD`.

Tests and project generation:

```sh
swift test                               # shared logic, no screen, microphone or network access
python3 scripts/generate-project.py      # after adding Swift files
```

Releases: pushing a tag like `v0.3.0` builds the DMG on the `macos-26` runner and publishes a GitHub Release. `bash scripts/release.sh 0.3.0` builds the same DMG locally into `dist/`.

### Project layout

```text
SiriPlus/
  App/          App, AppModel (chat, attachments, dictation), MeetingModel (meeting and hints),
                histories, updates, usage limits
  Features/     Windows: chat, meeting, settings, ask panel, update prompt
  Models/       Messages, settings, transcript and question detector
  Services/     Model providers, audio capture and speech recognition, media transcription,
                Keychain, screenshots, hotkey, updater
  Intents/      Siri and Shortcuts action
  Resources/    Info.plist, entitlements, string catalogs (en, ru), icons
SiriPlusWidget/ Desktop widget
Tests/          Unit tests
```

UI strings are written in English in code; the Russian translation lives in `Resources/Localizable.xcstrings`.

## Support

Siri+ is free and open source. If it saves you time on calls, you can support development on [Boosty](https://boosty.to/rtm00). Bug reports and pull requests help a lot too.
