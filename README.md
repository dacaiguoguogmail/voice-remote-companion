# Voice Remote Companion

[English](README.md) | [简体中文](README.zh-CN.md)

Use an iPhone as a push-to-talk microphone and shortcut remote for a Mac. The phone streams audio over the local network to a Mac companion, which plays it through a loopback device such as BlackHole. A separate dictation app, such as Wispr Flow, performs speech recognition and inserts the resulting text.

> **Status:** experimental. The UI currently uses Chinese. The project has been used on an iPhone 13 with Wispr Flow, but the revised pairing flow and other environments still need real-device testing.

## Features

- Push to talk, with a microphone level meter and haptic feedback.
- Discover a Mac with Bonjour or enter its IP address manually.
- Trigger a dictation shortcut on the Mac with Ctrl or Fn.
- Send common keys, switch apps, open Codex, and select conversations using Command + 1–9.
- Automatically retry dropped connections while the phone app is active.
- A single-screen remote layout, designed around iPhone 13.

## How it works

```text
iPhone microphone → local TCP → VoiceRemoteMac → BlackHole → dictation app → active text field
                                     └→ simulated keyboard shortcuts
```

This project does **not** perform speech recognition, show transcripts on the phone, or include an audio driver. The dictation app and loopback device are installed separately.

## Requirements

- A Mac running macOS 14 or later, Xcode, and an iPhone running iOS 27 or later.
- A compatible loopback audio device, such as [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), and a Mac dictation app that accepts it as input.
- A trusted local network that lets the devices communicate over TCP port `45971`.
- An Apple development team and a unique bundle identifier for signing the iPhone app. The `com.example` bundle identifiers in the project are **placeholders**, not a shared Apple account or a ready-to-use signing identity.

The current UI is Chinese and the only extensively exercised device layout is iPhone 13. Availability of a particular OS, Xcode version, device or dictation app depends on the user's environment.

## Setup

1. Install BlackHole 2ch following its instructions. In `Companion.xcodeproj`, select the `VoiceRemoteMac` scheme and run it on the Mac.
2. Select **BlackHole 2ch** as the Mac companion's audio output. Select the matching voice trigger (Ctrl, Fn or none). If using shortcut simulation, grant the Mac app Accessibility permission when prompted.
3. Select the `VoiceRemotePhone` scheme. In **Signing & Capabilities**, choose your own development team and replace the example bundle identifier with one available to you. Build and run on your iPhone; allow local network and microphone access.
4. On the phone, open connection settings and enter the six-digit pairing code shown in the Mac app. Select the discovered Mac. If Bonjour discovery is unavailable, enter a reachable Mac IP and connect manually. A code is generated and stored on the Mac; the phone stores a successfully used code for reconnecting.
5. Configure your dictation app to use BlackHole as its microphone and the same trigger shortcut. Focus a text field on the Mac, then hold the phone's talk button and speak.

The Mac and phone may need local-network permission. Changing a bundle identifier, signing identity or app path can also require granting Accessibility permission again. Bonjour may not be available on every hotspot or network; use the manual IP fallback when needed.

## Security and privacy

**Use only on a trusted network.** Pairing codes, audio and commands are transmitted over unencrypted TCP. The six-digit code does not protect against an observer on the network; do not expose the listener to the public Internet. Successfully used pairing codes are stored in the phone's app preferences, and the Mac stores its generated code in its app preferences. They are not stored in the Keychain.

The Mac companion can simulate input in other applications when granted Accessibility permission. Audio may be processed or uploaded by the dictation app according to that app's own policies. See [SECURITY.md](SECURITY.md).

## Build from source

Open `Companion.xcodeproj` in Xcode and select either `VoiceRemotePhone` or `VoiceRemoteMac`. The following command checks the iOS build without signing and does not install it on a device:

```sh
xcodebuild -project Companion.xcodeproj -scheme VoiceRemotePhone \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

To build and install on an iPhone, set up signing in Xcode with your own Apple team and identifiers. The repository contains no certificates, provisioning profiles or Apple team setting.

## Troubleshooting

- **No Mac found:** Check that both apps are running, local-network permission is enabled and the devices can reach each other. Try the manual IP shown by the Mac app.
- **Repeated pairing failures:** Check the code in the Mac window. The Mac temporarily rejects new connections for 30 seconds after an incorrect code.
- **Audio but no text:** Select BlackHole in both the companion and your dictation app, match their trigger shortcuts, check Accessibility permission, and focus an editable field.
- **No sound:** Check microphone permission on the phone, the selected Mac output device, and the volume meters on both ends.

See the [English code guide](docs/CODE_GUIDE.md) or [中文代码导读](docs/CODE_GUIDE.zh-CN.md) for the connection, audio and shortcut flow. Source-code comments are currently Chinese.

## License

[MIT](LICENSE). Independently installed third-party software, including BlackHole, has its own license.
