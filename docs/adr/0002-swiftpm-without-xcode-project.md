# 2. Use Swift Package Manager without a checked-in Xcode project

Date: 2026-09-26

## Status

Accepted

## Context

`.xcodeproj` files are hard to review and cause frequent merge conflicts, which hurts an open
source project with many contributors. Generators such as XcodeGen or Tuist solve this but add
a tool every contributor must install.

SwiftPM can build a macOS executable directly, Xcode opens `Package.swift` natively, and
`xcodebuild` can build package schemes. However, `swift build` copies String Catalogs
(`.xcstrings`) without compiling them; only `xcodebuild` compiles them into `.lproj` tables.

## Decision

- `Package.swift` is the single source of truth for targets and dependencies.
- `swift build` / `swift run` / `swift test` are the day-to-day development loop.
- `Scripts/build-app.sh` builds with `xcodebuild` and assembles `Momo.app` (Info.plist, resource
  bundles, ad-hoc or Developer ID signature). This is the only way to get localized builds.
- The app sets its activation policy in code, so it behaves correctly under `swift run` without
  an Info.plist.

## Consequences

- No project file conflicts; contributors need only Xcode.
- UI text is English when launched with `swift run`; translators use `make app`.
- When we need app extensions, widgets or complex entitlements, we will revisit this decision
  (XcodeGen is the likely replacement).
