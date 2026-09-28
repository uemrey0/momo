# 7. Listen and speak only with Momo's own voice models

Date: 2026-09-28

## Status

Accepted. Amends [ADR 0006](0006-open-source-voice-helper.md): voice features no longer work
without the helper.

## Context

Momo had two on-device voice stacks: Apple's (Speech, SpeechAnalyzer and the system voices)
and the open source models in the `momo-voice` helper, with Apple's as the fallback whenever
the helper wasn't ready. In practice the fallback was what people heard most: right after
every update the helper's models needed their first load, and Apple's voices stood in. They
sound far worse than Kokoro and Supertonic, and Apple's recognition mixed Turkish and English
badly. Two stacks also meant two sets of behaviour, permissions (Speech Recognition) and bugs.

## Decision

- Every part of Momo that listens or speaks on the Mac runs on the helper's models: live
  conversation, dictation, the wake word, replies read aloud, spoken yes-or-no answers and
  meeting transcription. The helper gains sessions that only listen or only speak, and the
  transcription of recordings.
- Momo uses no Apple speech recognition and no system voices. Until the models are downloaded
  and ready for the Mac's language, voice features don't start and say where to get the
  models. Cloud engines the user chose with their own key (OpenAI and Gemini transcription,
  OpenAI voices, cloud realtime voice) stay, and fall back to the voice models.
- The models' first load for a new helper build runs in the background at launch, so a
  conversation doesn't wait on it.
- Users pick the speech model and voice, and may add a Kokoro or Supertonic Core ML model
  folder or a voice style file of their own; the helper validates and copies them into its
  model folder.

## Consequences

- Voice sounds the same everywhere, and there is one stack to test and fix.
- Voice features need macOS 15 and Apple Silicon (the helper's requirements) and a model
  download (about 1.1 GB for English or Turkish) before first use. Momo itself still runs on
  macOS 14 without them.
- The Speech Recognition permission is no longer asked.
- The protocol moved to version 2, so app and helper must ship together, as before.
