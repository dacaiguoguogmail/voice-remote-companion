# Code guide

English | [简体中文](CODE_GUIDE.zh-CN.md)

This guide explains the implementation; see the [README](../README.md) for setup. Source comments remain in Chinese to support the original learning workflow.

## Files

| File | Purpose |
| --- | --- |
| `Phone/PhoneApp.swift` | iPhone app entry point, discovery, connection state, audio capture and remote UI. |
| `Mac/MacApp.swift` | Mac app entry point, service advertising, authentication, audio output and keyboard control. |
| `Shared/Wire.swift` | Shared TCP framing and JSON message representation. |
| `Phone/DiscoveryInfo.plist`, `Mac/DiscoveryInfo.plist` | Bonjour service declarations. |
| `Companion.xcodeproj/project.pbxproj` | Xcode targets, platform requirements, placeholder identifiers and build settings. |
| `.gitignore` | Files and local build products excluded from Git. |
| `README.md`, `README.zh-CN.md` | English and Chinese setup, use and limitations. |
| `LICENSE`, `SECURITY.md` | Project license and security boundaries. |

## Connection flow

1. `MacApp` creates `MacModel`, whose initializer loads audio devices and IP addresses and starts the TCP listener on port 45971 and Bonjour advertising.
2. `PhoneApp` creates `PhoneModel`. `RemoteView` starts Bonjour discovery. A previously selected unique service or the only discovered service may be selected automatically.
3. On first use the user enters the Mac's generated code in connection settings and selects a Mac. Manual IP connection is also supported.
4. `connect(to:)` creates a `Wire` and sends an `auth` message when TCP is ready. `MacModel.accept(_:)` holds pending handshakes; `handle(_:from:)` verifies the code and returns `ready`.
5. A newly authenticated connection replaces an old session. Failed connections retry after three seconds; a pending attempt is cancelled after eight seconds. Attempt IDs guard against stale callbacks.

The code is generated and stored in Mac app preferences and the phone stores a successful code in its preferences. This is not encrypted authentication: see [SECURITY.md](../SECURITY.md).

## Voice flow

1. The phone's talk control invokes `startVoice()`, requests microphone access, and uses `captureGeneration` to disregard callbacks after a release or a new capture.
2. `beginCapture()` configures the audio session, sends `voice_start`, converts microphone buffers to 16 kHz mono signed 16-bit PCM, measures the level, and sends Base64 `audio` messages.
3. The Mac's `startVoice()` starts an audio engine on the selected output and optionally presses the configured trigger key. `play(_:)` validates and schedules each received buffer.
4. `stopVoice()` on the phone ends capture and sends `voice_stop`. On the Mac, `stopVoice(immediate:)` releases the simulated key and stops the engine after playback, or immediately after a disconnect. A timeout prevents a lost playback callback from leaving a key pressed.
5. BlackHole exposes the playback as an input to an external dictation app. That app, not this project, produces the text.

## Commands and messages

`PhoneModel.command(_:)` sends a command and gives local feedback. `MacModel.command(_:)` maps known commands to application activation or keyboard events delivered to the current foreground app. Effects depend on that app's shortcuts and Accessibility permission.

`Wire` sends newline-delimited JSON. TCP is a byte stream, so `receive()` buffers partial frames and splits on newlines. It cancels if unprocessed data exceeds 256 KiB. Message types are `auth`, `ready`, `voice_start`, `audio`, `voice_stop`, `command` and `error`.

## SwiftUI and concurrency

`@StateObject` owns a model, `@ObservedObject` observes it, and `@Published` triggers view updates. Models are `@MainActor`; callbacks use main-actor tasks or dispatch to update UI state. Weak captures avoid retaining old sessions. Capture, playback and connection generation values protect newer work from stale callbacks.

## Where to make changes

- Remote controls: `RemoteView`, `chatPicker(height:)`, and `RemoteKey` in the phone file.
- Command mappings: phone `command(_:)` and Mac `command(_:)`.
- Audio format: update phone conversion and Mac format, level calculation and timing together.
- Discovery and pairing: phone `startDiscovery()` / `connect(to:)` and Mac `start()` / `accept(_:)` / `handle(_:from:)`.
- Platform, signing and permissions: project settings and both Bonjour plists.
