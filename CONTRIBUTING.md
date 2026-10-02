# Contributing to Momo

Thanks for helping make Momo better. This guide explains how we work so that your change can be
reviewed and merged quickly.

## Ways to contribute

- **Code:** bug fixes, features from the [roadmap](docs/roadmap.md), performance work.
- **Translations:** add or improve a language in the String Catalogs.
- **Character packs:** new looks for Momo, see [docs/character-packs.md](docs/character-packs.md).
- **Docs and design:** clearer docs, better onboarding, accessibility reviews.
- **Issues:** well-described bug reports and feature ideas.

For anything bigger than a small fix, please open an issue first so we can agree on the approach
before you invest time.

## Development setup

1. Install Xcode 26.6 or later. CI builds, tests and lints with Xcode 26.6 on GitHub's
   `macos-26` runners (pinned in `.github/workflows/ci.yml` and `release.yml`). Newer Xcode
   versions are fine for development, but their Swift compiler can report concurrency
   diagnostics that Xcode 26.6 doesn't, and the other way round, so if CI fails on something
   that builds locally, check the "Show toolchain" step first.
2. Clone the repository and run:

   ```bash
   make test   # build and run the tests
   make run    # launch Momo from the command line
   ```

3. Optional: open `Package.swift` in Xcode.

Useful targets:

| Command          | What it does                                              |
| ---------------- | --------------------------------------------------------- |
| `make test`      | Build and run all tests                                   |
| `make run`       | Launch Momo from the command line (English UI)            |
| `make app`       | Build `dist/Momo.app` with translations and `momo-mcp`    |
| `make dmg`       | Pack `dist/Momo-<version>.dmg`                            |
| `make lint`      | Check formatting (`make format` fixes it)                 |
| `make l10n`      | Check that every UI string is translated                  |
| `make snapshots` | Regenerate the README images and animated hero (needs ffmpeg) |
| `make icon`      | Regenerate the app icon from the character renderer       |

Debug builds also understand `--snapshot <folder>` (render the UI and README banners),
`--render-hero-frames <folder>`, `--render-icon <file>` and `--ask "<message>"` (run one message through the whole assistant,
optionally with `--brain-url` and `--brain-model` for an OpenAI-compatible server).

## Branches

`main` is always releasable. Work on a short-lived branch named after the change type:

| Prefix       | Use for                                  |
| ------------ | ---------------------------------------- |
| `feature/`   | New functionality                        |
| `fix/`       | Bug fixes                                |
| `docs/`      | Documentation only                       |
| `refactor/`  | Code changes that don't alter behaviour  |
| `chore/`     | Tooling, CI, dependencies                |

Example: `feature/character-packs`, `fix/notch-position-external-display`.

## Commit messages

We follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). The history
feeds our changelog, so please keep it clean.

```
<type>(<optional scope>): <summary in the imperative, lower case, no period>

<optional body explaining what and why, wrapped at 72 characters>

<optional footer, e.g. "Fixes #42" or "BREAKING CHANGE: ...">
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`,
`revert`.

Common scopes: `face`, `app`, `brain`, `voice`, `tools`, `i18n`, `docs`.

Examples:

```
feat(face): add sleepy head nod to the idle behaviours
fix(app): keep the notch panel above full-screen apps
docs: explain the brain router decision order
```

Each commit should build and pass the tests on its own. Squash fixup commits before asking for
review.

## Pull requests

1. Rebase on the latest `main`.
2. Run `make lint` and `make test`. `make lint` uses the `swift format` that comes with your
   Xcode, and the committed `.swift-format` files list every rule explicitly, so it gives the
   same result as CI's. `Tests/.swift-format` and `Helpers/momo-voice/Tests/.swift-format`
   are copies of the root config that turn off `NeverForceUnwrap` and `NeverUseForceTry`,
   because older `swift format` versions only exempt `@Test` functions, not test helpers.
   If you change the root config, change those two the same way.
3. Fill in the pull request template, including screenshots or a short screen recording for
   anything visual.
4. Keep pull requests focused. Two small PRs are easier to review than one large one.

A maintainer will review within a few days. We may ask for changes; that is a normal part of the
process.

CI doesn't start on its own for pull requests, because its macOS runners are expensive. Once a
maintainer has looked at the changes, they add the `ci: run` label, and CI then runs on that
push and every later one. Until then, the local `make lint` and `make test` runs are what
counts.

## Code style

- Swift 6 language mode with strict concurrency. UI and engine types are `@MainActor`.
  Callbacks that run on other threads (audio taps, delegates, process handlers) must be
  created outside main-actor code, or Swift 6 will trap at runtime.
- Format with `swift format` using the repository's `.swift-format` config (`make format`).
- Prefer small, focused types. Document public API with `///` comments.
- No force unwraps outside tests unless the invariant is explained in a comment.
- Every user-facing string goes through a String Catalog. Never hard-code UI text.

## Tests

We use [Swift Testing](https://developer.apple.com/documentation/testing). Add tests for new
logic, especially in `MomoFace` and future `MomoBrain` code. Engine code takes an injectable
random number generator so behaviour can be tested deterministically.

## Localization

User-facing strings live in `Sources/MomoApp/Resources/Localizable.xcstrings`, with English
as the source language. In code, use `L("English text")` and `String(format:)` for values
(never interpolation inside `L`). `make l10n` fails when a string lacks a translation.

To add a language:

1. Open the catalog in Xcode and add the language, or edit the JSON directly.
2. Translate every string and mark it `translated`.
3. Add `Scripts/InfoPlist/<code>.strings` (permission prompts) and the code to
   `CFBundleLocalizations` in `Scripts/Info.plist` and `LOCALIZATIONS` in
   `Scripts/build-app.sh`.
4. Run `make l10n`, build with `make app` and check the UI in that language.

To add strings from a script or the command line, pass a JSON map of English keys to their
translations to `Scripts/add-translations.py`; it keeps Xcode's formatting.

Parallel branches that add strings would conflict in the catalog, so it merges as JSON through
a git merge driver. Enable it once per clone:

```bash
git config merge.xcstrings.name "String Catalog merge"
git config merge.xcstrings.driver "python3 Scripts/merge-xcstrings.py %O %A %B"
```

## Architecture decisions

Significant decisions are recorded as ADRs in [`docs/adr`](docs/adr). If your change alters one
of them, add a new ADR that supersedes it.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
