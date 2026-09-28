import Foundation
import MomoLiveProtocol
import MomoVoiceCore
import MomoVoiceEngine

// `momo-voice`: Momo's on-device live voice helper.
//
// Without arguments it speaks the live voice protocol: one JSON command per line on standard
// input, one JSON event per line on standard output, diagnostics on standard error. The
// options below are for trying the engine by hand.

let usage = """
    Usage: momo-voice                      Speak the live voice protocol on stdin/stdout.
           momo-voice --say TEXT [--locale L] [--tts MODEL] [--voice V]
                                           Synthesise TEXT and play it (microphone closed).
           momo-voice --listen [--locale L] [--levels]
                                           Print what the microphone hears until Ctrl-C.
           momo-voice --transcribe FILE [L] Transcribe a recording with timestamps.
           momo-voice --list-models [L] [--tts MODEL]
                                           List the models and voices, marking the ones a
                                           conversation in L needs.
           momo-voice --prepare [L] [--mode conversation|listen|speak]
                                           Load and warm up the models L needs.
           momo-voice --download ID...      Download models (see --list-models).
           momo-voice --delete ID...        Delete downloaded or added models.
           momo-voice --import-model FOLDER Add a Kokoro or Supertonic Core ML model.
           momo-voice --import-voice MODEL FILE
                                           Add a voice file to a speech model.
           momo-voice --delete-voice MODEL VOICE
                                           Delete a voice that was added.
    Models are kept in ~/Library/Application Support/Momo/Models.
    """

signal(SIGPIPE, SIG_IGN)
Log.info("Started, live voice protocol \(liveVoiceProtocolVersion)")

/// Writes events as JSON lines to standard output.
final class EventWriter: Sendable {
    private let lock = NSLock()

    func write(_ event: LiveVoiceEvent) {
        guard let data = try? LiveVoiceCoding.line(event) else { return }
        lock.withLock { FileHandle.standardOutput.write(data) }
    }
}

/// Reads standard input line by line on its own thread, so a busy engine never stops input
/// from being read.
func readLines() -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    let thread = Thread {
        var buffer = LiveVoiceLineBuffer()
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { break }
            for line in buffer.append(data) { continuation.yield(line) }
        }
        continuation.finish()
    }
    thread.name = "momo-voice.stdin"
    thread.start()
    return stream
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func values(after flag: String, in arguments: [String]) -> [String] {
    guard let index = arguments.firstIndex(of: flag) else { return [] }
    return arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
        .flatMap { $0.split(separator: ",").map(String.init) }
}

func printLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func runProtocol() {
    let writer = EventWriter()
    let engine = VoiceEngine(emit: writer.write)
    let server = LiveVoiceServer(backend: engine, emit: writer.write)
    let lines = readLines()
    Task {
        for await line in lines where await server.handle(line: line) == .quit {
            Log.info("Quit")
            exit(0)
        }
        // End of input: Momo went away.
        await server.shutDown()
        Log.info("Input closed")
        exit(0)
    }
}

func runListen(locale: String, showsLevels: Bool) {
    let engine = VoiceEngine { event in
        switch event {
        case .listening: printLine("Listening… (Ctrl-C to stop)")
        case .speechStarted: printLine("● speech")
        case .partial(let text): printLine("  … \(text)")
        case .level(let level) where showsLevels && level > 0.2:
            printLine(String(format: "  level %.2f", level))
        case .turn(let text): printLine("» \(text)")
        case .error(let message, _): printLine("error: \(message)")
        case .stopped: printLine("stopped")
        default: break
        }
    }
    Task {
        do {
            try await engine.start(LiveSessionConfiguration(locale: locale, mode: .listen))
            // Keep the engine, and with it the audio session, alive until Ctrl-C.
            while !Task.isCancelled { try await Task.sleep(for: .seconds(3600)) }
            await engine.stop()
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runSay(_ text: String, arguments: [String]) {
    let configuration = LiveSessionConfiguration(
        locale: value(after: "--locale", in: arguments) ?? "en-US",
        textToSpeechModel: value(after: "--tts", in: arguments),
        voice: value(after: "--voice", in: arguments))
    let engine = VoiceEngine { event in
        if case .error(let message, _) = event { printLine("error: \(message)") }
    }
    Task {
        do {
            try await engine.say(text, configuration: configuration)
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runListModels(locale: String, textToSpeechModel: String?) {
    let engine = VoiceEngine { _ in }
    Task {
        let models = await engine.models(locale: locale, textToSpeechModel: textToSpeechModel)
        printLine("Models for \(locale) (* = required, ✓ = downloaded, + = added by you):")
        for info in models {
            let license = ModelCatalog.model(id: info.id)?.license ?? ""
            let size = String(format: "%6.0f MB", Double(info.sizeBytes) / 1_000_000)
            let marks =
                (info.isRequired ? "*" : " ") + (info.isDownloaded ? "✓" : " ")
                + (info.isCustom ? "+" : " ")
            let name = info.id.padding(toLength: 32, withPad: " ", startingAt: 0)
            printLine("\(marks) \(name) \(size)  \(license)  \(info.name)")
            if !info.voices.isEmpty {
                let voices = info.voices.map { info.customVoices.contains($0) ? "\($0)+" : $0 }
                printLine("     voices: \(voices.joined(separator: " "))")
            }
        }
        if ModelSelection.plan(locale: locale) == nil {
            printLine("Momo cannot hold a conversation in \(locale).")
        }
        exit(0)
    }
}

func runPrepare(locale: String, mode: LiveSessionMode) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            let startedAt = Date()
            try await engine.prepare(LiveSessionConfiguration(locale: locale, mode: mode))
            printLine(
                "Prepared \(locale) (\(mode.rawValue)) in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
            )
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runTranscribe(path: String, locale: String) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            let startedAt = Date()
            let segments = try await engine.transcribe(path: path, locale: locale)
            for segment in segments {
                printLine(
                    String(format: "[%7.2f – %7.2f] ", segment.start, segment.end) + segment.text)
            }
            printLine(
                "\(segments.count) segments in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
            )
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runImportModel(path: String) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            printLine("Added as \(try await engine.importModel(path: path))")
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runImportVoice(modelID: String, path: String) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            let voice = try await engine.importVoice(modelID: modelID, path: path)
            printLine("Added voice \(voice) to \(modelID)")
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runDeleteVoice(modelID: String, voice: String) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            try await engine.deleteVoice(modelID: modelID, voice: voice)
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

func runDownload(ids: [String]) {
    let engine = VoiceEngine { event in
        switch event {
        case .downloadProgress(let id, let fraction):
            printLine(String(format: "%@ %3.0f%%", id, fraction * 100))
        case .downloadFinished(let id): printLine("\(id) done")
        case .downloadFailed(let id, let message): printLine("\(id) failed: \(message)")
        default: break
        }
    }
    Task {
        await engine.downloadModels(ids: ids)
        exit(0)
    }
}

func runDelete(ids: [String]) {
    let engine = VoiceEngine { _ in }
    Task {
        do {
            try await engine.deleteModels(ids: ids)
            exit(0)
        } catch {
            printLine("error: \(error)")
            exit(1)
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil:
    runProtocol()
case "--say":
    guard let text = value(after: "--say", in: arguments) else {
        printLine(usage)
        exit(2)
    }
    runSay(text, arguments: arguments)
case "--listen":
    runListen(
        locale: value(after: "--locale", in: arguments) ?? "en-US",
        showsLevels: arguments.contains("--levels"))
case "--list-models":
    runListModels(
        locale: values(after: "--list-models", in: arguments).first ?? "en-US",
        textToSpeechModel: value(after: "--tts", in: arguments))
case "--prepare":
    guard
        let mode = LiveSessionMode(
            rawValue: value(after: "--mode", in: arguments) ?? "conversation")
    else {
        printLine(usage)
        exit(2)
    }
    runPrepare(locale: values(after: "--prepare", in: arguments).first ?? "en-US", mode: mode)
case "--transcribe":
    let operands = Array(arguments.dropFirst())
    guard let path = operands.first else {
        printLine(usage)
        exit(2)
    }
    runTranscribe(path: path, locale: operands.dropFirst().first ?? "en-US")
case "--import-model":
    guard let path = arguments.dropFirst().first else {
        printLine(usage)
        exit(2)
    }
    runImportModel(path: path)
case "--import-voice", "--delete-voice":
    let operands = Array(arguments.dropFirst())
    guard operands.count >= 2 else {
        printLine(usage)
        exit(2)
    }
    if arguments.first == "--import-voice" {
        runImportVoice(modelID: operands[0], path: operands[1])
    } else {
        runDeleteVoice(modelID: operands[0], voice: operands[1])
    }
case "--download":
    runDownload(ids: values(after: "--download", in: arguments))
case "--delete":
    runDelete(ids: values(after: "--delete", in: arguments))
case "--version":
    printLine("momo-voice, live voice protocol \(liveVoiceProtocolVersion)")
    exit(0)
default:
    printLine(usage)
    exit(arguments.first == "--help" ? 0 : 2)
}

// The engine runs on tasks and dispatch queues; the main thread only waits.
dispatchMain()
