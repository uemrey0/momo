# Security Policy

Momo can read your calendar, your notes, and later your screen and parts of your file system, and
it can talk to AI providers on your behalf. We take its security seriously.

## Supported versions

Momo is pre-release software. Only the latest commit on `main` and the latest release receive
security fixes.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/uemrey0/momo/security/advisories/new).
Include:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- The Momo version or commit, and your macOS version

We aim to acknowledge reports within 3 working days and to ship a fix or mitigation within
30 days for confirmed high-severity issues. We will credit you in the release notes unless you
prefer to stay anonymous.

## Scope

Examples of issues we especially want to hear about:

- Data leaving the Mac without the user's consent, or without personal data masking
- API keys or provider credentials exposed outside the macOS Keychain
- Actions performed on the user's computer without the required confirmation
- Code execution through character packs or MCP servers
- The `momo-mcp` server offering destructive tools without `--allow-destructive`
