# Roadmap

Each phase ends with a tagged, usable release. Estimates assume one core developer.

## Phase 0: A living character (in progress)

- Repository, Swift package, CI, contribution guidelines
- Notch panel (top centre on displays without a notch)
- `MomoFace` engine: five layers, twelve moods, idle behaviours, cursor tracking, poke physics
- Menu bar controls for moods, simulated events and brain colour
- String Catalogs with English and Turkish

**Done when:** Momo breathes, watches the cursor and dozes off when the user is away, all without
any AI.

## Phase 1: Local brain and chat panel

- Chat panel that opens from the character, streamed replies, expressions that follow the
  conversation
- Apple Foundation Models with an MLX fallback; first-run assistant for hardware, language and
  model choice
- Tasks, notes and reminders as tools
- Character pack format (JSON looks and mood parameters) with two example packs

**Done when:** "Remind me to call Ayşe tomorrow at 3" works fully offline.

## Phase 2: Bring your own subscription

- Codex app-server adapter (ChatGPT plan), Agent Client Protocol client (Gemini CLI)
- API key providers (Anthropic, OpenAI, Google, OpenRouter) stored in the Keychain
- Brain router, personal data masking, outbound request log

**Done when:** a long PDF question is answered through the user's ChatGPT plan after they
confirm, and Momo's eyes change colour while it happens.

## Phase 3: Voice

- Push-to-talk, "Hey Momo" wake word, interruptible speech
- Lip sync from speech synthesis word boundaries

## Phase 4: Context and reactions

- Reactions to calendar, music, battery, screen sharing and late-night use
- MCP server (Claude, Codex and other agents can use Momo's tools) and MCP client
- Long-term memory, morning brief, focus mode

## Phase 5: Superpowers and community (towards 1.0)

- Screen understanding and confirmed computer actions
- In-app gallery for character packs and skills
- Homebrew cask, Sparkle updates, community translations for 8+ languages
