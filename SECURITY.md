# Security

English | [简体中文](SECURITY.zh-CN.md)

Voice Remote Companion is experimental and intended only for a trusted local network.

- TCP pairing messages, audio and commands are **not encrypted**. An observer on the network may read the pairing code and audio, and a party who learns the code can send commands. The code is stored in application preferences on both devices, not Keychain.
- Do not forward port 45971 or expose the service to the public Internet. Bonjour advertises the service on available local interfaces.
- Accessibility permission allows the Mac app to simulate keyboard input in other applications. Review the source and install only builds you trust.
- The separate dictation tool controls how it processes or uploads audio; review its privacy policy.
- Encryption, secure pairing, replay protection, a formal security audit, and a vulnerability reporting channel are not implemented yet. Do not include pairing codes, audio or private data in public issue reports.
