# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Momo no longer hides in the notch and pops back out on its own, which was distracting.
  Idle behaviours now play every 8–18 seconds instead of every 4–8, quiet ones far more often
  than big ones, and never the same one twice in a row.
- Motion feels more natural: slower breathing with a quick inhale and a long exhale, a gentle
  sway, eyes that hold a glance and make tiny movements, blinks on big glances, eyes that lag
  behind the swinging body, and a cursor that stops being interesting once it sits still.
- Moods are livelier: Momo nods while listening and speaking, looks from spot to spot while
  thinking, reads line by line while focused, sniffles when sad and sleeps soundly when the
  user is away, then stretches on waking.

### Added

- New idle behaviours: sneezing, shaking itself off, a curious head tilt, whistling, a tongue
  "blep", watching the screen, daydreaming, sighing and nodding off. It yawns and nods off
  more as the user stays away. A new mail makes Momo perk up instead of hiding.

### Fixed

- Settings did not open from the menu or the panel on macOS 14 and later. Settings now has
  its own window, and Momo shows a Dock icon while Settings or the welcome tour is open so
  they always come to the front.

## [0.1.0] - 2026-09-26

The first release: a living companion in the notch that works with the brain you already have.

### Added

- A procedural character that breathes, blinks, follows the cursor, reacts to pokes, dozes
  off when you are away and shows twelve moods, with seven looks and custom JSON character
  packs.
- A chat panel (⌥Space or click Momo) with streamed Markdown replies, tool activity, brain
  labels, consent before remote brains and confirmation before sensitive actions.
- Today and Notes tabs for tasks, reminders, habits with streaks and notes.
- Brains: Apple Intelligence, Ollama, LM Studio, the ChatGPT plan through Codex CLI, a Google
  account through Gemini CLI, and Claude, OpenAI, Gemini and OpenRouter API keys.
- Automatic routing between local and remote brains, personal data masking and a log of
  everything sent.
- Tools for tasks, notes, habits, memory, calendar, apps, links, Shortcuts, the clipboard,
  the screen and focus sessions.
- Voice: on-device dictation (⌥⇧Space), spoken replies with lip sync and an optional
  "Hey Momo" wake word.
- Reactions to meetings, reminders, music, low battery and late nights, plus a morning
  greeting.
- The `momo-mcp` server for Claude, Codex and other agents, and connections to the user's own
  MCP servers.
- English and Turkish, onboarding, settings, launch at login and update checks.

[Unreleased]: https://github.com/uemrey0/momo/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/uemrey0/momo/releases/tag/v0.1.0
