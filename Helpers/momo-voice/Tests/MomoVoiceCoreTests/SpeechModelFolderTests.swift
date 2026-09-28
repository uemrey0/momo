import Foundation
import Testing

@testable import MomoVoiceCore

/// Builds model folders with small stand-in files in a temporary directory.
struct FolderFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-voice-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `contents` to `path` under the fixture, creating folders on the way.
    @discardableResult
    func write(_ path: String, _ contents: String = "{}") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A Kokoro voice embedding with `count` numbers.
    static func kokoroVoice(count: Int = 256) -> String {
        "{\"embedding\": [\(Array(repeating: "0.1", count: count).joined(separator: ","))]}"
    }

    /// A Supertonic voice style with the given number of values.
    static func supertonicVoice(ttl: Int = 50 * 256, dp: Int = 8 * 16) -> String {
        let ttlData = Array(repeating: "0.5", count: ttl).joined(separator: ",")
        let dpData = Array(repeating: "1", count: dp).joined(separator: ",")
        return
            "{\"style_ttl\": {\"dims\": [1, 50, 256], \"data\": [[\(ttlData)]]}, "
            + "\"style_dp\": {\"data\": [\(dpData)]}}"
    }

    /// A complete Kokoro conversion in `name`.
    func kokoro(_ name: String = "Kokoro") throws -> URL {
        try write("\(name)/vocab_index.json", "{\"a\": 1, \"b\": 2}")
        try write("\(name)/kokoro_5s.mlmodelc/model.mil", "")
        try write("\(name)/voices/af_heart.json", Self.kokoroVoice())
        return root.appendingPathComponent(name)
    }

    /// A complete Supertonic conversion in `name`.
    func supertonic(_ name: String = "Supertonic") throws -> URL {
        try write("\(name)/unicode_indexer.json", "[0, 1, 2, -1]")
        for graph in ["DurationPredictor", "TextEncoder", "VectorEstimator"] {
            try write("\(name)/\(graph).mlpackage/Manifest.json")
        }
        try write("\(name)/Vocoder.mlmodelc/model.mil", "")
        try write("\(name)/voice_styles/F1.json", Self.supertonicVoice())
        return root.appendingPathComponent(name)
    }
}

@Suite("Model folders and voice files")
struct SpeechModelFolderTests {
    @Test("recognises complete Kokoro and Supertonic conversions")
    func recognises() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        #expect(try SpeechModelFolder.architecture(of: fixture.kokoro()) == .kokoro)
        #expect(try SpeechModelFolder.architecture(of: fixture.supertonic()) == .supertonic)
    }

    @Test("names what a model folder lacks")
    func missingFiles() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        try fixture.write("Half/vocab_index.json", "{\"a\": 1}")
        #expect(
            throws: SpeechModelImportError.missingFiles(
                architecture: .kokoro, files: ["kokoro_5s.mlmodelc", "the voices folder"])
        ) {
            try SpeechModelFolder.architecture(of: fixture.root.appendingPathComponent("Half"))
        }

        let supertonic = try fixture.supertonic()
        try FileManager.default.removeItem(
            at: supertonic.appendingPathComponent("TextEncoder.mlpackage"))
        let error = #expect(throws: SpeechModelImportError.self) {
            try SpeechModelFolder.architecture(of: supertonic)
        }
        #expect(error?.description.contains("TextEncoder") == true)
    }

    @Test("refuses folders that are not models, and models without usable voices")
    func refuses() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        try fixture.write("Photos/cat.jpg", "")
        #expect(throws: SpeechModelImportError.unrecognizedFolder("Photos")) {
            try SpeechModelFolder.architecture(of: fixture.root.appendingPathComponent("Photos"))
        }
        let file = try fixture.write("file.txt", "")
        #expect(throws: SpeechModelImportError.notAFolder(file.path)) {
            try SpeechModelFolder.architecture(of: file)
        }

        let kokoro = try fixture.kokoro()
        try fixture.write("Kokoro/voices/af_heart.json", FolderFixture.kokoroVoice(count: 10))
        #expect(throws: SpeechModelImportError.noVoices(architecture: .kokoro)) {
            try SpeechModelFolder.architecture(of: kokoro)
        }

        let supertonic = try fixture.supertonic()
        try fixture.write("Supertonic/unicode_indexer.json", "{\"not\": \"a list\"}")
        #expect(throws: SpeechModelImportError.self) {
            try SpeechModelFolder.architecture(of: supertonic)
        }
    }

    @Test("checks that voice files hold what the loader reads")
    func voices() throws {
        let fixture = try FolderFixture()
        defer { fixture.remove() }
        let kokoro = try fixture.write("k.json", FolderFixture.kokoroVoice())
        let supertonic = try fixture.write("s.json", FolderFixture.supertonicVoice())
        let shortStyle = try fixture.write("short.json", FolderFixture.supertonicVoice(dp: 127))
        let text = try fixture.write("voice.txt", FolderFixture.kokoroVoice())

        try SpeechModelFolder.validateVoice(at: kokoro, architecture: .kokoro)
        try SpeechModelFolder.validateVoice(at: supertonic, architecture: .supertonic)
        #expect(throws: SpeechModelImportError.invalidVoice(name: "s.json", architecture: .kokoro))
        {
            try SpeechModelFolder.validateVoice(at: supertonic, architecture: .kokoro)
        }
        #expect(
            throws: SpeechModelImportError.invalidVoice(
                name: "short.json", architecture: .supertonic)
        ) {
            try SpeechModelFolder.validateVoice(at: shortStyle, architecture: .supertonic)
        }
        #expect(throws: SpeechModelImportError.notAVoiceFile("voice.txt")) {
            try SpeechModelFolder.validateVoice(at: text, architecture: .kokoro)
        }
    }

    @Test("voice names are safe and unique")
    func voiceNames() {
        #expect(SpeechModelFolder.voiceName(for: "Emre.json", existing: []) == "Emre")
        #expect(
            SpeechModelFolder.voiceName(for: "my voice (2).json", existing: []) == "my_voice__2")
        #expect(SpeechModelFolder.voiceName(for: "../evil.json", existing: []) == "evil")
        #expect(SpeechModelFolder.voiceName(for: "ğüş.json", existing: []) == "voice")
        #expect(
            SpeechModelFolder.voiceName(for: "F1.json", existing: ["F1", "F1-2", "M1"]) == "F1-3")
        #expect(SpeechModelFolder.voiceName(for: "f1.json", existing: ["F1"]) == "f1-2")
    }

    @Test("folder names become short identifiers")
    func slugs() {
        #expect(SpeechModelFolder.slug(for: "My Kokoro!") == "my-kokoro")
        #expect(SpeechModelFolder.slug(for: "Kokoro-82M CoreML (v2)") == "kokoro-82m-coreml-v2")
        #expect(SpeechModelFolder.slug(for: "Türkçe") == "t-rk-e")
        #expect(SpeechModelFolder.slug(for: "…") == "model")
        #expect(SpeechModelFolder.slug(for: String(repeating: "a", count: 50)).count == 32)
    }

    @Test("errors read well for the user")
    func messages() {
        let missing = SpeechModelImportError.missingFiles(
            architecture: .supertonic, files: ["tts.json", "Vocoder.mlpackage"])
        #expect(
            missing.description == "This Supertonic model is missing tts.json, Vocoder.mlpackage.")
        #expect(missing.errorDescription == missing.description)
    }
}

@Suite("Speech stretches")
struct SpeechStretchesTests {
    @Test("joins stretches with short pauses")
    func merges() {
        let merged = SpeechStretches.merge([
            SpeechStretch(start: 5.0, end: 6.0),
            SpeechStretch(start: 0.0, end: 1.0),
            SpeechStretch(start: 1.5, end: 2.0),
            SpeechStretch(start: 2.7, end: 3.0),
            SpeechStretch(start: 4.0, end: 3.5),
        ])
        #expect(
            merged == [
                SpeechStretch(start: 0.0, end: 2.0), SpeechStretch(start: 2.7, end: 3.0),
                SpeechStretch(start: 5.0, end: 6.0),
            ])
    }

    @Test("keeps joined stretches short")
    func capsLength() {
        let stretches = (0..<10).map {
            SpeechStretch(start: Double($0) * 5, end: Double($0) * 5 + 4.8)
        }
        let merged = SpeechStretches.merge(stretches, longest: 12)
        #expect(merged.count == 5)
        #expect(merged.allSatisfy { $0.end - $0.start <= 12 })
    }
}
