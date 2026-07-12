# Ollama Voice

iOS app that chats with **Ollama** at `100.64.0.2:11434` (configurable), searches/pulls models to that host, and downloads **Piper**, **Kokoro**, and **[Chatterbox](https://github.com/resemble-ai/chatterbox)** speech models for on-device / offline TTS. STT uses Apple’s on-device Speech framework. Voice clones (reference WAV) are saved locally for Chatterbox-style zero-shot TTS.

## Features

- **Chat** — streaming Ollama chat, mic input (on-device STT), optional spoken replies
- **Models** — browse curated catalog, search, pull/delete on the Ollama host
- **Voice** — pick TTS engine (Apple / Piper / Kokoro / Chatterbox), download models, record/import voice clones
- **Settings** — Ollama host/port, optional Chatterbox HTTP sidecar, permissions

## Open on Mac

```bash
cd OllamaVoice
brew install xcodegen   # once
xcodegen generate
open OllamaVoice.xcodeproj
```

Select your Team for signing, pick an iPhone / simulator, Run.

Default Ollama URL: `http://100.64.0.2:11434` (Tailscale → panzer). Cleartext HTTP to the Tailscale/LAN hosts is allowed via ATS exceptions in `Info.plist`.
