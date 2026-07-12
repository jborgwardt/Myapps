# LonelyBull

Voice-first iOS app. On-device **STT** (Apple Speech) and **TTS** — **Piper**, **Kokoro**, and **[Chatterbox](https://github.com/resemble-ai/chatterbox)** models download straight from Hugging Face, and voice clones (reference audio) are stored locally for Chatterbox-style zero-shot TTS. **Ollama is an optional backend**: add a host in Settings when you want streaming chat and server-side model pulls.

## Design

Cursor-for-iOS-inspired monochrome dark UI: near-black backdrop, plain assistant text with right-aligned user bubbles, monospace host/model pills, and a floating rounded composer. On iOS 26+ (incl. iOS 27) the pills, composer, and buttons render with **Liquid Glass** (`glassEffect`, `.glass`/`.glassProminent` button styles, tab bar minimizes on scroll); earlier iOS falls back to ultra-thin materials. Deployment target stays iOS 17. App icon: an angry bull with evil glowing eyes.

## Features

- **Chat** — streaming Ollama chat, mic input (on-device STT), optional spoken replies, model picker pill
- **Models** — paste `ollama run …` / ollama.com links, Hugging Face GGUF search with quant resolution, live pull progress, curated abliterated suggestions
- **Voice** — pick TTS engine (Apple / Piper / Kokoro / Chatterbox), search + download speech models, record/import voice clones
- **Settings** — optional Ollama host/port/scheme, optional Chatterbox HTTP sidecar, permissions

## Open on Mac

```bash
cd LonelyBull
brew install xcodegen   # once
xcodegen generate
open LonelyBull.xcodeproj
```

Select your Team for signing, pick an iPhone / simulator, Run.

An unsigned IPA for external signing/sideloading lands in `dist/LonelyBull-unsigned.ipa`. Cleartext HTTP to Tailscale/LAN hosts is allowed via ATS exceptions in `Info.plist`.
