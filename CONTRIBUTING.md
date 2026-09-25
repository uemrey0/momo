# Contributing to Momo

Thanks for helping make Momo better. This guide explains how we work so that your change can be
reviewed and merged quickly.

## Ways to contribute

- **Code:** bug fixes, features from the [roadmap](docs/roadmap.md), performance work.
- **Translations:** add or improve a language in the String Catalogs.
- **Character packs:** new looks and moods for Momo (format lands in Phase 0/1).
- **Docs and design:** clearer docs, better onboarding, accessibility reviews.
- **Issues:** well-described bug reports and feature ideas.

For anything bigger than a small fix, please open an issue first so we can agree on the approach
before you invest time.

## Development setup

1. Install Xcode 16 or later.
2. Clone the repository and run:

   ```bash
   make test   # build and run the tests
   make run    # launch Momo from the command line
   ```

3. Optional: open `Package.swift` in Xcode.

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
2. Run `make lint` and `make test`.
3. Fill in the pull request template, including screenshots or a short screen recording for
   anything visual.
4. Keep pull requests focused. Two small PRs are easier to review than one large one.

A maintainer will review within a few days. We may ask for changes; that is a normal part of the
process.

## Code style

- Swift 6 language mode with strict concurrency. UI and engine types are `@MainActor`.
- Format with `swift format` using the repository's `.swift-format` config (`make format`).
- Prefer small, focused types. Document public API with `///` comments.
- No force unwraps outside tests unless the invariant is explained in a comment.
- Every user-facing string goes through a String Catalog. Never hard-code UI text.

## Tests

We use [Swift Testing](https://developer.apple.com/documentation/testing). Add tests for new
logic, especially in `MomoFace` and future `MomoBrain` code. Engine code takes an injectable
random number generator so behaviour can be tested deterministically.

## Localization

User-facing strings live in `Sources/<Module>/Resources/Localizable.xcstrings`. English is the
source language. To add a language:

1. Open the catalog in Xcode and add the language, or edit the JSON directly.
2. Translate every string and mark it `translated`.
3. Add the language code to `CFBundleLocalizations` in `Scripts/Info.plist`.
4. Build with `make app` and check the UI in that language.

## Architecture decisions

Significant decisions are recorded as ADRs in [`docs/adr`](docs/adr). If your change alters one
of them, add a new ADR that supersedes it.

## License

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
