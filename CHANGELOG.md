# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0-beta.2] - 2026-10-02

### Security

- A web page, file or other outside text that Momo reads can no longer make it send your
  data elsewhere on its own. Once a reply has read such text, Momo asks before:
  - opening or fetching a link you didn't give and a web search didn't return;
  - saving a memory.

  Outside text is marked as untrusted, so the model treats it as information rather than
  instructions. Momo also no longer reads the sign-ins of AI command-line tools (Codex,
  Gemini, Claude), shell histories or Mail data.
  ([GHSA-vgvc-c4j4-g6gv](https://github.com/uemrey0/momo/security/advisories/GHSA-vgvc-c4j4-g6gv))
- Routines can no longer be created, or have their prompt changed, without your approval.
  The approval shows the full prompt the routine will run. Other agents connected through
  `momo-mcp` can't add routines unless it is started with `--allow-destructive`.
  ([GHSA-7mhc-7w95-rhff](https://github.com/uemrey0/momo/security/advisories/GHSA-7mhc-7w95-rhff))
- Reading web pages can no longer be pointed at your local network or this Mac through
  addresses written in unusual ways, such as `127.1`, or names that point to a local address.
  Momo now looks up each site's address and checks it before connecting, and again after
  every redirect.
  ([GHSA-wgf5-6w3m-x847](https://github.com/uemrey0/momo/security/advisories/GHSA-wgf5-6w3m-x847))

## [0.2.0-beta.1] - 2026-10-02

### Added

- Momo's own voice models everywhere: dictation, "Hey Momo", replies read aloud, spoken
  questions and meeting notes run on the on-device models (Nemotron, Kokoro, Supertonic),
  like live conversation. Settings → Voice → Voice models picks the model and voice, and adds
  a Kokoro or Supertonic model folder or a voice style file of your own.
- Live conversation says what is happening: which brain works on a slow answer ("Checking
  with ChatGPT."), and why a reply failed (a usage limit, a sign-in, no internet) instead of a
  generic apology. Codex thinks briefly for spoken requests, so answers start sooner.
- Voice mode: ⌥⇧Space and "Hey Momo" work without opening the chat. A caption bubble under
  the notch shows what you said and Momo's answer while it is read aloud, and Momo's
  questions can be answered with "yes" or "no". Hold the shortcut to talk if you turn on
  push to talk.
- Cloud speech: OpenAI and Gemini transcription with your own key, and optional OpenAI
  voices.
- Meeting notes: Momo offers to take notes when a meeting starts, listens to you and the
  call as separate tracks, and writes a summary with decisions, action items, open questions
  and participants. Action items become tasks in one click; a Meetings tab keeps the
  transcripts. Audio is not kept unless you ask.
- ChatGPT (Codex) and Gemini CLI can use every Momo tool through a private bridge, with the
  same confirmations and personal data masking as other brains.
- Web search (no key needed, or Brave Search with a key) and reading web pages.
- Conversations are saved and searchable, and follow-up questions remember what the tools
  found. Attach files, images and screenshots to a message; brains that can see get the
  images.
- Momo across the Mac: files (find, read, list, reveal, move to the Trash), Reminders,
  Contacts, Mail drafts, Messages, Music and Spotify, volume, dark mode, display sleep, lock
  screen, quitting apps, battery and Wi-Fi status, weather, AppleScript and shell commands
  (always shown and confirmed first), and what's on screen ("summarise this").
- Momo is hidden from screen recordings and screen sharing (Settings → Privacy).
- Memory ranks what it remembers by relevance and sorts memories into categories.
- Tasks can repeat and have a priority and tags; routines run a prompt on a schedule, such
  as a morning summary.

### Changed

- Apple's voices and Apple speech recognition are gone. Until Momo's voice models are
  downloaded and ready, voice mode doesn't start and says where to get them; the models get
  ready in the background at launch. The Speech Recognition permission is no longer asked.
- The panel has a fresh, friendlier design and now grows and shrinks with its content
  instead of always being the same size. Sections have icons and a sliding highlight, and
  the brain picker, Settings and Close live in a small "⋯" menu.
- Chat: Momo's answers come in bubbles next to a tiny, blinking Momo, and messages slide in
  with a spring. Which brain answered and what Momo did shows when you point at an answer.
  The empty chat greets you for the time of day with suggestion cards.
- Today opens with the date and a progress ring, ticking a task pops, finished tasks move to
  a "Done today" list, and habits show the last seven days.
- Notes are colourful cards in two columns, with a softer editor that slides in.

- Settings has a sidebar with search, like System Settings, and opens on the new AI page.
  Right-clicking Momo opens a menu with Settings, and Momo points you to AI setup from the
  chat, the menu bar and the sidebar until a brain is connected.
- Connecting a brain no longer needs Terminal. Each option on the AI page has a short guided
  setup: ChatGPT uses the Codex engine inside the ChatGPT app and signs in through the
  browser; Ollama downloads a model with a progress bar, sized for your Mac; API keys are
  spotted when you copy them and checked with the provider before they are saved.
- Momo can add itself to Claude Desktop, Claude Code and Codex with one click.
- Google Gemini now uses your Google account (and Google AI Pro or Ultra) instead of an API
  key, so there are no extra charges. Momo downloads Google's official Gemini CLI, checks it
  against the published checksum and starts the Google sign-in. The Gemini API with a key is
  a separate option. ChatGPT can likewise download the official Codex tool when the ChatGPT
  app isn't installed.
- Pick a model from a list instead of typing its name. Each connection's setup shows the
  models the provider offers, with readable names, short descriptions and its recommendation;
  long lists can be searched. The AI page shows which model each connection uses.

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
- Attached files show in the chat while they load, the paperclip lines up with the text
  field, and the file picker stays in front of the panel. Brains are shown with their logos.

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

[Unreleased]: https://github.com/uemrey0/momo/compare/v0.2.0-beta.2...HEAD
[0.2.0-beta.2]: https://github.com/uemrey0/momo/compare/v0.2.0-beta.1...v0.2.0-beta.2
[0.2.0-beta.1]: https://github.com/uemrey0/momo/compare/v0.1.0...v0.2.0-beta.1
[0.1.0]: https://github.com/uemrey0/momo/releases/tag/v0.1.0
