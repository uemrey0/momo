# 5. Speak MCP in both directions

Date: 2026-09-26

## Status

Accepted

## Context

Users already work with agents such as Claude Desktop, Claude Code and Codex, and some run
their own MCP servers (GitHub, file systems, databases). Momo holds personal data those agents
could use (tasks, notes, memories), and those servers offer tools Momo's brains could use.

Claude subscriptions cannot be used by third-party apps (see ADR 0003), but Claude can use MCP
servers the user adds.

## Decision

- Ship `momo-mcp`, a stdio MCP server inside the app bundle that serves the same store tools
  the in-app assistant uses. It shares the data file with the app, so changes appear on both
  sides immediately.
- Tools that need confirmation (deleting data) are not offered unless `--allow-destructive` is
  passed, because Momo cannot show its own confirmation there; the calling agent must ask.
- Offer `momo-mcp` to the Codex CLI bridge, so ChatGPT-plan answers can use Momo's tools.
- Add an MCP client: the user can connect their own servers in Settings. Their tools are
  offered to Momo's brains with a name prefix and ask before each call by default.
- Implement the protocol ourselves (JSON-RPC over stdio, `initialize`, `tools/list`,
  `tools/call`) instead of adding a dependency, since Momo only needs tools.

## Consequences

- Claude users can use Momo with their subscription through Claude itself.
- Only the tools part of MCP is supported; resources and prompts can be added later.
- Third-party servers run with the user's permissions; the settings warn to add only trusted
  servers.
