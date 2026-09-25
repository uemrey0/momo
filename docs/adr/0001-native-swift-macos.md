# 1. Build a native Swift app for macOS only

Date: 2026-09-26

## Status

Accepted

## Context

Momo lives in the notch, listens for a wake word, reads the calendar, and later watches the
screen and performs actions. It should feel instant and use very little memory while idle.

We considered three stacks:

- **Tauri 2 (Rust + web UI):** small, cross-platform, but notch windows, speech, calendar and
  on-device models all need native bridges.
- **Electron (TypeScript):** the largest contributor pool, but heavy for an always-on companion.
- **Swift + SwiftUI/AppKit:** direct access to `NSPanel`, Foundation Models, SpeechAnalyzer,
  AVSpeechSynthesizer, EventKit, ScreenCaptureKit and the Accessibility API. macOS only.

The project has decided to target macOS only for now.

## Decision

Build Momo as a native Swift 6 app using SwiftUI with AppKit where needed. Support macOS 14 and
later, and enable macOS 26 features (Foundation Models, SpeechAnalyzer) at runtime when
available.

Keep business logic (brain routing, tools, character engine) in library modules without AppKit
dependencies where practical, so a future port can reuse it.

## Consequences

- Best possible notch integration, lowest idle cost, and no bundled runtime.
- A Windows or Linux version would need a new UI layer.
- Contributors need a Mac and Xcode.
