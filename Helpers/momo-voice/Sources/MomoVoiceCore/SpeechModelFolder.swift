import Foundation

/// Why a model folder or a voice file cannot be added. The descriptions are written for the
/// user: Momo shows them as they are.
public enum SpeechModelImportError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The path is not a folder.
    case notAFolder(String)
    /// The folder holds neither a Kokoro nor a Supertonic conversion.
    case unrecognizedFolder(String)
    /// The folder looks like a model of `architecture` but lacks these files.
    case missingFiles(architecture: SpeechArchitecture, files: [String])
    /// A file is there but not in the form the model needs.
    case invalidFile(name: String, reason: String)
    /// The model has no voice file the helper can use.
    case noVoices(architecture: SpeechArchitecture)
    /// The folder is Momo's model folder or inside it.
    case insideModelFolder
    /// The model is not a speech synthesis model on this Mac.
    case notASpeechModel(String)
    /// A voice file must be a `.json` file.
    case notAVoiceFile(String)
    /// The voice file does not hold a voice of the model's architecture.
    case invalidVoice(name: String, architecture: SpeechArchitecture)
    /// Only voices the user added can be deleted.
    case notACustomVoice(String)

    public var description: String {
        switch self {
        case .notAFolder(let path):
            "\(path) is not a folder."
        case .unrecognizedFolder(let name):
            "The folder \(name) does not hold a speech model Momo can run. Choose a Core ML "
                + "conversion of Kokoro (with vocab_index.json, kokoro_5s.mlmodelc and a voices "
                + "folder) or of Supertonic (with unicode_indexer.json, the DurationPredictor, "
                + "TextEncoder, VectorEstimator and Vocoder models and a voice_styles folder)."
        case .missingFiles(let architecture, let files):
            "This \(architecture.displayName) model is missing "
                + "\(files.joined(separator: ", "))."
        case .invalidFile(let name, let reason):
            "The file \(name) cannot be used: \(reason)."
        case .noVoices(let architecture):
            "This \(architecture.displayName) model has no voice Momo can use in its "
                + "\(SpeechModelFolder.voicesDirectory(for: architecture)) folder."
        case .insideModelFolder:
            "The folder is already in Momo's model folder. Choose the folder you downloaded."
        case .notASpeechModel(let id):
            "\(id) is not a speech synthesis model on this Mac."
        case .notAVoiceFile(let name):
            "\(name) is not a voice file. Voice files end in .json."
        case .invalidVoice(let name, let architecture):
            switch architecture {
            case .kokoro:
                "\(name) is not a Kokoro voice: it needs an \"embedding\" list of at least "
                    + "\(SpeechModelFolder.kokoroStyleDimension) numbers."
            case .supertonic:
                "\(name) is not a Supertonic voice style: it needs \"style_ttl\" data of "
                    + "\(SpeechModelFolder.supertonicTTLCount) numbers and \"style_dp\" data of "
                    + "\(SpeechModelFolder.supertonicDPCount) numbers."
            }
        case .notACustomVoice(let voice):
            "The voice \(voice) came with the model and cannot be deleted."
        }
    }

    public var errorDescription: String? { description }
}

/// What a folder must hold for speech-swift to load it as a Kokoro or Supertonic model, and
/// what voice files must look like. It only reads files; ``ModelStore`` copies them.
///
/// The rules follow speech-swift 0.0.28: `KokoroTTSModel.fromPretrained` needs
/// `vocab_index.json`, an end-to-end `.mlmodelc` and voice embeddings in `voices/`;
/// `SupertonicTTSModel` needs `unicode_indexer.json`, four graphs (`.mlmodelc` or
/// `.mlpackage`) and voice styles in `voice_styles/`.
public enum SpeechModelFolder {
    /// The length of a Kokoro voice embedding (`KokoroConfig.styleDim`).
    public static let kokoroStyleDimension = 256
    /// The numbers in a Supertonic `style_ttl` (50 × 256).
    public static let supertonicTTLCount = 50 * 256
    /// The numbers in a Supertonic `style_dp` (8 × 16).
    public static let supertonicDPCount = 8 * 16

    /// The names Kokoro's end-to-end model may have, in the order speech-swift tries them.
    static let kokoroModelNames = ["kokoro_5s", "kokoro_10s", "kokoro_15s", "kokoro"]
    /// The four Supertonic graphs.
    static let supertonicGraphs = [
        "DurationPredictor", "TextEncoder", "VectorEstimator", "Vocoder",
    ]

    /// The folder in a model that holds its voices.
    public static func voicesDirectory(for architecture: SpeechArchitecture) -> String {
        switch architecture {
        case .kokoro: "voices"
        case .supertonic: "voice_styles"
        }
    }

    /// Checks that `folder` holds a model the helper can load and says which kind it is.
    ///
    /// - Throws: ``SpeechModelImportError`` naming what is missing or wrong.
    public static func architecture(of folder: URL) throws -> SpeechArchitecture {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw SpeechModelImportError.notAFolder(folder.path)
        }
        let kokoroHints =
            ["vocab_index.json"] + kokoroModelNames.map { "\($0).mlmodelc" } + ["voices"]
        let supertonicHints =
            ["unicode_indexer.json", "voice_styles"]
            + supertonicGraphs.flatMap { ["\($0).mlmodelc", "\($0).mlpackage"] }
        let kokoroScore = kokoroHints.filter { exists($0, in: folder) }.count
        let supertonicScore = supertonicHints.filter { exists($0, in: folder) }.count
        guard kokoroScore > 0 || supertonicScore > 0 else {
            throw SpeechModelImportError.unrecognizedFolder(folder.lastPathComponent)
        }
        let architecture: SpeechArchitecture =
            supertonicScore > kokoroScore ? .supertonic : .kokoro
        switch architecture {
        case .kokoro: try validateKokoro(folder)
        case .supertonic: try validateSupertonic(folder)
        }
        return architecture
    }

    private static func validateKokoro(_ folder: URL) throws {
        var missing: [String] = []
        if !exists("vocab_index.json", in: folder) { missing.append("vocab_index.json") }
        if !kokoroModelNames.contains(where: { exists("\($0).mlmodelc", in: folder) }) {
            missing.append("kokoro_5s.mlmodelc")
        }
        if !exists("voices", in: folder) { missing.append("the voices folder") }
        let hasG2P =
            exists("G2PEncoder.mlmodelc", in: folder) && exists("G2PDecoder.mlmodelc", in: folder)
        if hasG2P, !exists("g2p_vocab.json", in: folder) { missing.append("g2p_vocab.json") }
        guard missing.isEmpty else {
            throw SpeechModelImportError.missingFiles(architecture: .kokoro, files: missing)
        }
        let vocabulary = folder.appendingPathComponent("vocab_index.json")
        let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: vocabulary))
        let isFlat = json is [String: Int]
        let isNested = (json as? [String: Any])?["vocab"] is [String: Int]
        guard isFlat || isNested else {
            throw SpeechModelImportError.invalidFile(
                name: "vocab_index.json", reason: "it is not a map from phonemes to numbers")
        }
        try requireVoices(in: folder, architecture: .kokoro)
    }

    private static func validateSupertonic(_ folder: URL) throws {
        var missing: [String] = []
        if !exists("unicode_indexer.json", in: folder) { missing.append("unicode_indexer.json") }
        for graph in supertonicGraphs
        where !exists("\(graph).mlmodelc", in: folder) && !exists("\(graph).mlpackage", in: folder)
        {
            missing.append("\(graph).mlpackage")
        }
        if !exists("voice_styles", in: folder) { missing.append("the voice_styles folder") }
        guard missing.isEmpty else {
            throw SpeechModelImportError.missingFiles(architecture: .supertonic, files: missing)
        }
        let indexer = folder.appendingPathComponent("unicode_indexer.json")
        guard (try? JSONSerialization.jsonObject(with: Data(contentsOf: indexer))) is [Any] else {
            throw SpeechModelImportError.invalidFile(
                name: "unicode_indexer.json", reason: "it is not a list of numbers")
        }
        try requireVoices(in: folder, architecture: .supertonic)
    }

    private static func requireVoices(in folder: URL, architecture: SpeechArchitecture) throws {
        let directory = folder.appendingPathComponent(voicesDirectory(for: architecture))
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        let hasVoice = files.contains { file in
            file.pathExtension == "json" && isVoice(at: file, architecture: architecture)
        }
        guard hasVoice else { throw SpeechModelImportError.noVoices(architecture: architecture) }
    }

    /// Checks that the file at `url` is a voice a model of `architecture` can load.
    ///
    /// - Throws: ``SpeechModelImportError/notAVoiceFile(_:)`` or
    ///   ``SpeechModelImportError/invalidVoice(name:architecture:)``.
    public static func validateVoice(at url: URL, architecture: SpeechArchitecture) throws {
        guard url.pathExtension.lowercased() == "json" else {
            throw SpeechModelImportError.notAVoiceFile(url.lastPathComponent)
        }
        guard isVoice(at: url, architecture: architecture) else {
            throw SpeechModelImportError.invalidVoice(
                name: url.lastPathComponent, architecture: architecture)
        }
    }

    /// Whether the file holds a voice in the shape speech-swift's loader accepts.
    static func isVoice(at url: URL, architecture: SpeechArchitecture) -> Bool {
        guard let data = try? Data(contentsOf: url),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        switch architecture {
        case .kokoro:
            guard let embedding = json["embedding"] as? [Double] else { return false }
            return embedding.count >= kokoroStyleDimension
        case .supertonic:
            guard let ttl = (json["style_ttl"] as? [String: Any])?["data"],
                let dp = (json["style_dp"] as? [String: Any])?["data"]
            else { return false }
            return numberCount(ttl) == supertonicTTLCount && numberCount(dp) == supertonicDPCount
        }
    }

    /// How many numbers a nested JSON list holds, or -1 when it holds anything else.
    private static func numberCount(_ value: Any) -> Int {
        if value is NSNumber { return 1 }
        guard let list = value as? [Any] else { return -1 }
        var count = 0
        for item in list {
            let inner = numberCount(item)
            if inner < 0 { return -1 }
            count += inner
        }
        return count
    }

    /// A voice name made from a file name: letters, digits, `_` and `-` only, with a numeric
    /// suffix when `existing` already has it.
    ///
    /// - Parameters:
    ///   - fileName: The voice file's name, e.g. "My voice.json".
    ///   - existing: The model's voices.
    public static func voiceName(for fileName: String, existing: [String]) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let allowed = stem.unicodeScalars.map { scalar -> Character in
            let isAllowed =
                (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
                || scalar == "_" || scalar == "-"
            return isAllowed ? Character(scalar) : "_"
        }
        var base = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        if base.isEmpty { base = "voice" }
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// A short, safe identifier part made from a folder name, e.g. "my-kokoro" for
    /// "My Kokoro!".
    public static func slug(for name: String) -> String {
        var slug = ""
        for scalar in name.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(32))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "model" : slug
    }

    private static func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
}
