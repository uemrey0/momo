# 6. Run the open source live voice engine in a helper process

Date: 2026-09-26

## Status

Accepted

## Context

Live conversation needs a voice engine that listens and speaks at the same time: streaming
speech recognition with partial words, turn detection that hears when a sentence is finished,
echo cancellation so Momo does not hear itself, and fast speech synthesis. It should run on
the Mac, with open models, and speak Turkish as well as English.

The best open implementation for Apple Silicon is
[speech-swift](https://github.com/soniqo/speech-swift) (Apache-2.0): Silero VAD, Smart Turn,
Nemotron streaming recognition, Kokoro and Supertonic synthesis, on Core ML and MLX. It
requires macOS 15 and Apple Silicon, compiles Metal shaders with `xcodebuild`, and brings a
large dependency tree (MLX, swift-transformers and more).

Momo supports macOS 14 and has no third-party dependencies (ADR 0001, ADR 0002), which keeps
it small, auditable and quick to build.

## Decision

- Build the engine as `momo-voice`, a separate executable in its own Swift package,
  `Helpers/momo-voice` (macOS 15, Apple Silicon), which depends on speech-swift pinned to a
  release and on the root package's `MomoLiveProtocol` target only.
- Ship it in `Momo.app/Contents/MacOS` next to `momo-mcp`. Momo launches it as a child
  process and exchanges one JSON object per line over standard input and output
  (`MomoLiveProtocol`); diagnostics go to standard error.
- The helper owns the microphone and the speaker during a session, because echo cancellation
  (Apple's voice processing I/O) needs capture and playback in one audio engine. It never
  thinks: finished turns go to Momo, and Momo streams replies back sentence by sentence.
- Models are downloaded only when the user asks, from the published speech-swift conversions,
  into `~/Library/Application Support/Momo/Models`, and are loaded offline afterwards.
- The app works without the helper. It is built by `Scripts/build-app.sh` when the toolchain
  allows and signed with the hardened runtime and its own audio-input entitlement.

## Consequences

- Momo itself stays on macOS 14 with zero dependencies; only the helper needs macOS 15 and
  Apple Silicon, and Momo offers the on-device live voice only where the helper runs.
- A crash in the engine or a model cannot take the app down, and the helper's memory is
  returned when it quits.
- The protocol is a contract between two builds, so it carries a version checked in the
  handshake, and both sides must change together.
- The app bundle grows by the helper (about 55 MB); models (about 1.1 GB for English or
  Turkish) are separate downloads.
- Building the helper needs Xcode 16 or later and the Metal toolchain; CI builds and tests it
  in its own job.
