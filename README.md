# Momo

[![CI](https://github.com/uemrey0/momo/actions/workflows/ci.yml/badge.svg)](https://github.com/uemrey0/momo/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

**A tiny, living companion that sits in your Mac's notch and helps you get things done.**

Momo runs on your Mac first. It handles everyday tasks with on-device AI. When a job needs a
bigger brain, it asks before borrowing the subscription you already pay for (ChatGPT via Codex,
Google Gemini) or an API key you bring yourself. There is no Momo server, no account and no
paywall.

> **Status: pre-alpha (Phase 0).** Right now Momo is only a character: it breathes, blinks,
> follows your cursor, gets sleepy when you step away and reacts when you poke it. The assistant
> features land in the phases listed in the [roadmap](docs/roadmap.md).

## Highlights

- **Alive, not animated.** A procedural character engine (springs, layered behaviours, particles)
  makes Momo feel present without ever becoming distracting.
- **Local first.** Tasks, notes, reminders, voice and chat work offline on your Mac.
- **Bring your own brain.** Use your existing ChatGPT or Gemini plan through their official CLIs,
  or plug in an Anthropic, OpenAI, Google or OpenRouter API key. See
  [ADR 0003](docs/adr/0003-bring-your-own-subscription.md) for what is and isn't possible.
- **Private by default.** Nothing leaves your Mac without your consent, and personal data is
  masked before it does.
- **Multilingual from day one.** English and Turkish today, more through community translations.
- **Open and extensible.** Character packs, skills and translations are designed for
  contributors.

## Requirements

- macOS 14 Sonoma or later (some features need macOS 26)
- Apple silicon or Intel Mac
- Xcode 16 or later to build from source

## Build and run

```bash
git clone https://github.com/uemrey0/momo.git
cd momo
make run          # build and launch from the command line (English UI only)
make app          # build dist/Momo.app with all localizations
make test         # run the test suite
```

`make run` uses `swift run`, which is the fastest loop while developing. SwiftPM does not
compile String Catalogs on the command line, so use `make app` when you work on translations.

You can also open `Package.swift` in Xcode and run the `Momo` scheme.

Momo lives in the menu bar (look for the smiling face). Use that menu to change moods, simulate
events or quit.

## Project layout

```
Sources/
  MomoFace/     Character engine and renderer (usable on its own)
  MomoApp/      The macOS app: notch panel, menu bar, localization
Tests/
  MomoFaceTests/
docs/           Architecture, roadmap and architecture decision records (ADRs)
Scripts/        Build and packaging scripts
```

More modules (`MomoBrain`, `MomoVoice`, `MomoTools`) arrive with later phases. The
[architecture overview](docs/architecture.md) explains how they fit together.

## Contributing

Contributions are welcome, from code to character packs to translations. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) first.
To report a security issue, follow [SECURITY.md](SECURITY.md).

## Acknowledgements

Momo is inspired by [Taby](https://www.heytaby.com/). It is an independent project and is not
affiliated with Taby, Apple, OpenAI, Google or Anthropic.

## License

Momo is licensed under the [Apache License 2.0](LICENSE).
