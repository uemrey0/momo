# 3. Use the user's own subscriptions and keys instead of a hosted service

Date: 2026-09-26

## Status

Accepted

## Context

Momo is open source and has no server. Many users already pay for ChatGPT, Gemini or Claude and
would rather use that plan than buy API credits. Each provider has different rules for
third-party use of consumer plans:

- **OpenAI.** The official, open source Codex CLI signs in with a ChatGPT plan and offers an
  app server for programmatic use. The documentation does not explicitly forbid driving the
  user's own Codex installation from another app, but it recommends API keys for automation.
- **Google.** The official, open source Gemini CLI signs in with a Google account and speaks the
  Agent Client Protocol (ACP).
- **Anthropic.** The Claude Agent SDK documentation states that, unless previously approved,
  third-party developers may not offer claude.ai login or rate limits in their products.

## Decision

Momo supports these brains, in a user-defined priority order:

1. **On-device:** Apple Foundation Models, MLX or llama.cpp models, Ollama and LM Studio.
2. **The user's own subscription, through official CLIs the user installs and signs in to:**
   Codex CLI (`codex app-server`) and Gemini CLI (ACP). Momo launches these as child processes
   and never reads, stores or forwards their credentials.
3. **API keys** for Anthropic, OpenAI, Google and OpenRouter, stored in the macOS Keychain.

For Claude:

- Momo does not use claude.ai subscriptions. Claude is available through an Anthropic API key.
- Momo exposes its tools as an MCP server, so users can reach Momo from Claude Desktop or Claude
  Code with their own subscription.
- The maintainers will ask Anthropic for approval; if it is granted, a new ADR will supersede
  this section.

Before each release that ships a CLI bridge, maintainers re-check each provider's terms. CLI
bridges run with file editing disabled and in read-only sandbox mode.

## Consequences

- No hosted service, account or billing.
- CLI bridges depend on third-party tools that change; adapters check versions and fall back to
  the local brain when a bridge breaks.
- CLI start-up adds latency; adapters keep a long-lived process.
- Usage counts against the user's plan limits; Momo shows remaining usage when the CLI reports it.
