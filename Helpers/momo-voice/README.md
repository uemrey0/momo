# momo-voice

`momo-voice` is the helper process that runs Momo's open source, on-device voice models:
voice activity detection, end-of-turn detection, streaming speech recognition, echo
cancellation, speech synthesis and the transcription of recordings. Every part of Momo that
listens or speaks goes through it; Momo uses neither Apple's voices nor Apple's speech
recognition. It ships inside `Momo.app/Contents/MacOS` next to
`momo-mcp`. Momo starts it as a child process and speaks the JSON-lines protocol in
[`Sources/MomoLiveProtocol/LiveVoiceProtocol.swift`](../../Sources/MomoLiveProtocol/LiveVoiceProtocol.swift):
one command per line on standard input, one event per line on standard output. Diagnostics go
to standard error.

The first load of a new helper build compiles the models with Core ML, which took about 30 s
on an M1 (Nemotron alone about 22 s); later loads take 3 to 5 s. Momo therefore sends
`prepare` in the background before relying on a new build for a conversation.

It is a separate Swift package because the engine needs macOS 15, Apple Silicon and
[speech-swift](https://github.com/soniqo/speech-swift) (MLX and Core ML), while Momo itself
stays on macOS 14 with no third-party dependencies. See
[ADR 0006](../../docs/adr/0006-open-source-voice-helper.md).

## Models

Nothing is downloaded until Momo sends `downloadModels` (the user pressed Download) or you run
`momo-voice --download`. Models come from the speech-swift conversions on Hugging Face and are
kept in `~/Library/Application Support/Momo/Models/<id>`; after download they load with
speech-swift's offline mode, so a session never touches the network.

| ID | Kind | Model | Languages | Size | Weights license |
| -- | ---- | ----- | --------- | ---- | --------------- |
| `silero-vad` | Voice activity | [Silero VAD v6.2.1](https://huggingface.co/aufklarer/Silero-VAD-v6.2.1-CoreML), Core ML | any | 1 MB | MIT |
| `smart-turn-v3` | End of turn | [Pipecat Smart Turn v3.2](https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML), Core ML | 23, including en and tr | 17 MB | BSD-2-Clause |
| `nemotron-streaming-multilingual` | Speech recognition | [NVIDIA Nemotron 3.5 ASR Streaming 0.6B](https://huggingface.co/aufklarer/Nemotron-3.5-ASR-Streaming-0.6B-CoreML-INT8), Core ML INT8 | the 15 "transcription-ready" languages: ar, de, en, es, fr, hi, it, ja, ko, nl, pt, ru, tr, uk, vi | 642 MB | OpenMDW-1.1 |
| `kokoro-82m` | Speech synthesis | [Kokoro 82M](https://huggingface.co/aufklarer/Kokoro-82M-CoreML), Core ML | en, es, fr, hi, it, ja, pt, zh | 333 MB | Apache-2.0 |
| `supertonic-3` | Speech synthesis | [Supertone Supertonic 3](https://huggingface.co/aufklarer/Supertonic-3-CoreML), Core ML | 31, including tr | 400 MB | OpenRAIL-M (use restrictions: no impersonation, no undisclosed synthetic media) |

Which models a language uses:

| Language | Recognition | Speech |
| -------- | ----------- | ------ |
| English | Nemotron | Kokoro (`af_heart`, `bf_emma` for en-GB) |
| Turkish | Nemotron | Supertonic 3 (`F1`) |
| es, fr, hi, it, ja, pt | Nemotron | Kokoro |
| ar, de, ko, nl, ru, uk, vi | Nemotron | Supertonic 3 |
| other | not served (`start` fails) | Supertonic 3 or Kokoro where they speak it, for speak-only sessions |

`textToSpeechModel` in the session configuration can pick `kokoro-82m`, `supertonic-3` or a
model the user added; `voice` picks a Kokoro voice or a Supertonic style (`F1`–`F5`,
`M1`–`M5`), and `nil` uses the model's default (the table above, else its first voice). A
language no speech model speaks is an error.

### Models and voices the user adds

`importModel` copies a folder holding a Core ML conversion of Kokoro or Supertonic into
`custom-<name>-<6 hex>/` next to the other models, with a `momo-model.json` manifest (name,
architecture, size). It must hold what speech-swift loads:

- **Kokoro:** `vocab_index.json`, an end-to-end model (`kokoro_5s.mlmodelc`, or the 10 s,
  15 s or plain `kokoro` variant) and `voices/*.json` with at least one voice
  (`{"embedding": [256 or more numbers]}`). The G2P models, `g2p_vocab.json` and the
  pronunciation dictionaries are optional.
- **Supertonic:** `unicode_indexer.json`, `DurationPredictor`, `TextEncoder`,
  `VectorEstimator` and `Vocoder` (`.mlpackage` or `.mlmodelc`) and `voice_styles/*.json`
  with at least one style (`style_ttl.data` of 50 × 256 and `style_dp.data` of 8 × 16
  numbers).

Symbolic links in the folder (a Hugging Face snapshot, for example) are replaced with the
files they point to. An added model speaks the languages of its architecture's built-in model
and cannot be downloaded again; `deleteModels` removes it.

`importVoice` adds a voice file of the model's architecture to any downloaded speech model;
its name comes from the file name (letters, digits, `_` and `-`, with a number added when the
name is taken). Added voices are listed in the model's `.momo-custom-voices.json` and only
they can be removed with `deleteVoice`. Failures come back as `importFailed` with a message
for the user.

### How the models were chosen

Measured on an Apple M1 with 16 GB, macOS 27, release build:

| Step | Result |
| ---- | ------ |
| Nemotron streaming recognition | RTF 0.075 (≈25 ms per 320 ms chunk on the Neural Engine); first partial 0.2–0.9 s after speech is confirmed; final text 40–65 ms after the turn ends |
| End of turn | English: turn ended 0.38 s into the pause (Smart Turn 0.99). Turkish test voice: Smart Turn stayed below 0.5, so the turn ended at the `maximumPause` cap (1.2 s) |
| Kokoro, English | first audio 0.40 s after `speak`; RTF 0.10–0.27 |
| Supertonic 3 (CPU), Turkish | first audio 0.35 s after `speak`; RTF 0.13–0.24 |
| Model loading | 2.2 s for everything once Core ML has compiled the models (the first load after download takes about 20 s) |

- **Recognition.** Nemotron 3.5 lists Turkish as transcription-ready (FLEURS-class WER about
  12%) and streams with partial results, so it serves every language, English included.
  Parakeet EOU 120M was considered for English, but speech-swift 0.0.28 cannot load it from
  a chosen directory or offline, which Momo's model management needs; Smart Turn already
  covers end of utterance. Whisper was not needed because Nemotron handles Turkish.
  A new Nemotron session drops the first words when it starts cold on speech, so the
  helper keeps a session primed with a second of silence, and feeds it 0.4 s of audio from
  before the voice activity detector fired.
- **Turkish speech.** Candidates from speech-swift that claim Turkish, synthesising three
  Turkish sentences (1.1–6 s each) after a warm-up:

  | Model | First sentence | RTF | Peak memory | Weights license |
  | ----- | -------------- | --- | ----------- | --------------- |
  | Supertonic 3, Core ML on the CPU | 0.32 s | 0.14–0.19 | ~0.4 GB | OpenRAIL-M |
  | Supertonic 3, Neural Engine | 0.81 s | 0.33–0.60 | | |
  | Supertonic 3, GPU | crashes in MPSGraph (dynamic shapes) | | | |
  | Chatterbox Multilingual (MLX fp16) | 4.9 s | 1.9–2.4 | 0.85 GB | MIT |
  | VoxCPM2 (MLX int8) | 2.1 s | 1.8–2.1 | 2.9 GB | Apache-2.0 |
  | OmniVoice (MLX fp16, 12 steps) | 4.4 s | 1.6–2.5 | 1.05 GB | Apache-2.0 |

  Only Supertonic meets the target (first audio under 600 ms, RTF under 0.5), so Turkish uses
  it. Chatterbox and OmniVoice also need a reference voice
  recording. **Pronunciation and naturalness have not been judged by ear yet**: listen to
  `momo-voice --say "…" --locale tr-TR` before relying on it.
- **Echo cancellation.** The helper uses Apple's voice processing I/O
  (`AVAudioInputNode.setVoiceProcessingEnabled(true)`) with all speech played through the
  same `AVAudioEngine`. It needs no model, adapts to device
  changes and double-talk, and in testing cancelled not only Momo's own output but other
  apps' audio too. speech-swift's LocalVQE canceller needs the exact playback signal, time
  aligned with the microphone, and an extra model; its own documentation recommends Apple's
  processing where it works. If voice processing cannot be enabled, the session still runs
  without it and logs an error.

## Behaviour

- **Modes.** A `conversation` session listens and speaks with echo cancellation. A `listen`
  session (dictation, the wake word) loads only the listening models, opens only the
  microphone, without voice processing, and answers `speak` with a non-fatal `error`. A
  `speak` session (reading replies aloud) loads only the speech model and opens only the
  speaker: the microphone is never touched and no permission is asked. Each reports
  `listening` once it runs.
- **Listening.** Silero finds speech; after a 0.3 s pause Smart Turn hears whether the
  sentence is finished and either ends the turn or waits, up to `maximumPause`. `level` is
  reported every 100 ms, `partial` whenever the words change, `turn` with the final text.
  `pauseListening` stops turning speech into turns but keeps reporting levels.
- **Speaking.** `speak` chunks are split into sentences (long ones at a clause, and the first
  piece of a reply already at a comma after 60 characters). The first sentence plays as soon
  as it is synthesised while the next ones render behind it. `speakingStarted` comes when
  the utterance's first audio plays, `mouth` follows the output level every 50 ms, and
  `speakingFinished` comes after its last piece.
- **Barge-in.** With `allowsBargeIn`, speech that lasts 0.3 s while Momo talks stops playback
  at once and reports `interrupted`, then `speechStarted`; shorter speech is treated as echo.
  Without it, the user's speech is a turn and Momo keeps talking.
- **Transcription.** `transcribe` reads a recording with `AVAudioFile` (mixed down to
  16 kHz mono), finds speech with its own Silero VAD instance, joins stretches less than
  0.6 s apart (up to 30 s) and transcribes each with a fresh Nemotron session primed like a
  live turn. Nemotron sometimes drops the first word depending on where speech falls in its
  320 ms chunks, so each stretch is decoded at three offsets a third of a chunk apart and the
  longest text is kept. It runs beside the other commands, so a session keeps speaking; an
  18.8 s recording took 4.4 s on an M1.
- **Robustness.** Unreadable commands produce a non-fatal `error`. `quit` or the end of
  standard input stops the audio and exits.

## Building

The helper needs Xcode 16 or later (macOS 15 SDK), the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`) and an Apple Silicon Mac.

```sh
make voice-helper        # xcodebuild, Release, arm64 → .build/voice-helper/Build/Products/Release
make voice-helper-test   # the tests for the pure logic (MomoVoiceCore)
make app                 # also builds and bundles the helper
```

MLX compiles its Metal shaders only under `xcodebuild` (into `mlx-swift_Cmlx.bundle`);
`swift build` would leave them out. `Scripts/build-app.sh` copies `momo-voice` to
`Contents/MacOS` and its resource bundles (MLX's shaders, Kokoro's dictionaries) to
`Contents/Resources`, where `Bundle.module` and MLX find them because the helper's main
bundle is `Momo.app`. It signs the helper with the hardened runtime and
[`Scripts/momo-voice.entitlements`](../../Scripts/momo-voice.entitlements) (audio input), then
seals the app. Set `VOICE_HELPER=0` to skip the helper or `VOICE_HELPER=1` to fail when it does
not build; by default the app is built without it and a warning is printed. Momo runs fine
without the helper; the on-device live voice is then unavailable.

speech-swift is pinned to release 0.0.28 (`231f8eb`); `Package.resolved` pins everything else.

## Trying it by hand

```sh
momo-voice --list-models tr-TR                 # * = needed for tr-TR, ✓ = downloaded
momo-voice --download silero-vad smart-turn-v3 nemotron-streaming-multilingual supertonic-3
momo-voice --prepare tr-TR                     # loads and warms the models, no microphone
momo-voice --prepare tr-TR --mode listen       # conversation (default), listen or speak
momo-voice --say "Merhaba, nasılsın?" --locale tr-TR [--tts MODEL] [--voice V]
momo-voice --listen --locale tr-TR [--levels]  # prints partials and turns until Ctrl-C
momo-voice --transcribe meeting.wav tr-TR      # timed segments
momo-voice --import-model ~/Downloads/Kokoro-82M-CoreML
momo-voice --import-voice kokoro-82m my_voice.json
momo-voice --delete-voice kokoro-82m my_voice
momo-voice --delete kokoro-82m
```

For development, `MOMO_VOICE_MODELS_DIR` keeps models somewhere else and
`MOMO_VOICE_ECHO_CANCELLATION=0` turns echo cancellation off. The helper's timings (model
loading, first partial, turn end, first audio, real-time factor per sentence) are written to
standard error.

## Layout

| Target | What it holds |
| ------ | ------------- |
| `MomoVoiceCore` | Pure logic, tested: the model catalog and per-mode, per-language selection, the checks for added model folders and voice files, sentence splitting and the speech queue, the barge-in state machine, joining speech stretches, the protocol server. |
| `MomoVoiceEngine` | Audio and models: `VoiceEngine` (the protocol backend), `AudioIO` (one `AVAudioEngine` with voice processing), `Listener`, `Speaker`, `RecordingTranscriber`, the synthesizers and `ModelStore`. |
| `momo-voice` | The executable: the stdin reader and the command line modes. |
