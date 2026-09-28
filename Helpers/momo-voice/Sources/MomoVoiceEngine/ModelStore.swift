@preconcurrency import AudioCommon
import Foundation
import MomoLiveProtocol
import MomoVoiceCore

/// Where models live on disk: downloading, adding and deleting them, and their voices.
///
/// Each model gets its own directory under `~/Library/Application Support/Momo/Models`. A
/// model counts as downloaded only once every file arrived, which a marker file records, so
/// an interrupted download never loads half a model. Downloads resume where they stopped.
///
/// Models the user adds from a folder live in `custom-<slug>-<6 hex>` directories next to the
/// others, with a `momo-model.json` manifest giving their name, architecture and size. Voice
/// files the user adds are listed in the model directory's `.momo-custom-voices.json`.
public struct ModelStore: Sendable {
    /// The directory that holds every model.
    public let root: URL

    private static let completionMarker = ".momo-complete"
    private static let manifestName = "momo-model.json"
    private static let customVoicesName = ".momo-custom-voices.json"
    private static let customPrefix = "custom-"

    /// What a model the user added records about itself.
    private struct Manifest: Codable {
        var name: String
        var architecture: SpeechArchitecture
        var sizeBytes: Int64
    }

    public init(root: URL = ModelStore.defaultRoot) {
        self.root = root
    }

    /// `~/Library/Application Support/Momo/Models`, or the directory in the
    /// `MOMO_VOICE_MODELS_DIR` environment variable, for development.
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["MOMO_VOICE_MODELS_DIR"],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
                "Library/Application Support")
        return support.appendingPathComponent("Momo/Models", isDirectory: true)
    }

    // MARK: Models

    /// The directory of a model.
    public func directory(for model: VoiceModel) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    /// Whether every file of the model is on disk.
    public func isDownloaded(_ model: VoiceModel) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: model).appendingPathComponent(Self.completionMarker).path)
    }

    /// The models the user added, by name.
    public func customModels() -> [VoiceModel] {
        let directories =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
        return directories.compactMap { directory -> VoiceModel? in
            let id = directory.lastPathComponent
            guard id.hasPrefix(Self.customPrefix),
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(Self.completionMarker).path),
                let data = try? Data(
                    contentsOf: directory.appendingPathComponent(Self.manifestName)),
                let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            else { return nil }
            return VoiceModel(
                id: id, kind: .textToSpeech, name: manifest.name,
                languages: manifest.architecture.builtInModel.languages,
                sizeBytes: manifest.sizeBytes, license: "", repository: "", files: [],
                architecture: manifest.architecture, isCustom: true)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The built-in models followed by the ones the user added.
    public func allModels() -> [VoiceModel] {
        ModelCatalog.all + customModels()
    }

    /// The built-in or added model with `id`.
    public func model(id: String) -> VoiceModel? {
        if let model = ModelCatalog.model(id: id) { return model }
        return customModels().first { $0.id == id }
    }

    /// Downloads a model from its repository, reporting progress from 0 to 1.
    public func download(
        _ model: VoiceModel, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let directory = directory(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await HuggingFaceDownloader.downloadWeights(
            modelId: model.repository, to: directory, additionalFiles: model.files,
            progressHandler: { progress(min(1, max(0, $0))) })
        try Task.checkCancellation()
        try Data(model.repository.utf8).write(
            to: directory.appendingPathComponent(Self.completionMarker))
    }

    /// Deletes a model's files, including a partial download or a model the user added.
    public func delete(_ model: VoiceModel) throws {
        let directory = directory(for: model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Copies the Kokoro or Supertonic model in `folder` into the store.
    ///
    /// The copy goes to a hidden directory first and is renamed once complete, so a failed
    /// copy never shows up as a model.
    ///
    /// - Returns: The added model, named after the folder.
    /// - Throws: ``SpeechModelImportError`` when the folder does not hold a usable model, or
    ///   a file system error.
    public func importModel(from folder: URL) throws -> VoiceModel {
        let folder = folder.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        if folder.path == rootPath || folder.path.hasPrefix(rootPath + "/")
            || rootPath.hasPrefix(folder.path + "/")
        {
            throw SpeechModelImportError.insideModelFolder
        }
        let architecture = try SpeechModelFolder.architecture(of: folder)
        let name = folder.lastPathComponent
        let id =
            "\(Self.customPrefix)\(SpeechModelFolder.slug(for: name))-"
            + String(format: "%06x", UInt32.random(in: 0..<0x100_0000))

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".importing-\(id)", isDirectory: true)
        do {
            try Self.copyResolvingLinks(from: folder, to: staging)
            // Files left from a previous life of the folder must not count.
            for leftover in [Self.completionMarker, Self.manifestName, Self.customVoicesName] {
                try? fileManager.removeItem(at: staging.appendingPathComponent(leftover))
            }
            let manifest = Manifest(
                name: name, architecture: architecture, sizeBytes: Self.size(of: staging))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestName))
            try Data(name.utf8).write(to: staging.appendingPathComponent(Self.completionMarker))
            try fileManager.moveItem(at: staging, to: root.appendingPathComponent(id))
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        Log.info("Added \(architecture.displayName) model \(name) as \(id)")
        guard let model = model(id: id) else { throw VoiceEngineError.unknownModel(id) }
        return model
    }

    /// Copies a folder, replacing symbolic links with what they point to. Downloaded models
    /// often are links into a cache (Hugging Face snapshots use relative ones), which would
    /// break once copied.
    private static func copyResolvingLinks(
        from source: URL, to destination: URL, depth: Int = 0
    )
        throws
    {
        guard depth < 32 else { throw CocoaError(.fileReadTooLarge) }
        let fileManager = FileManager.default
        let resolved = source.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        guard isDirectory.boolValue else {
            try fileManager.copyItem(at: resolved, to: destination)
            return
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for child in try fileManager.contentsOfDirectory(
            at: resolved, includingPropertiesForKeys: nil)
        {
            try copyResolvingLinks(
                from: child, to: destination.appendingPathComponent(child.lastPathComponent),
                depth: depth + 1)
        }
    }

    /// The total size of the files under `directory`.
    private static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: Voices

    /// The voices of a downloaded speech synthesis model, sorted; empty for other models.
    public func voices(of model: VoiceModel) -> [String] {
        guard let directory = voicesDirectory(of: model), isDownloaded(model) else { return [] }
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// The voices among ``voices(of:)`` that the user added.
    public func customVoices(of model: VoiceModel) -> [String] {
        let voices = Set(voices(of: model))
        return recordedCustomVoices(of: model).filter(voices.contains)
    }

    /// Copies the voice file at `file` into a downloaded speech synthesis model.
    ///
    /// - Returns: The voice's name: the file's name, made safe and unique.
    /// - Throws: ``SpeechModelImportError`` when the model cannot take voices or the file is
    ///   not a voice of the model's architecture.
    public func importVoice(from file: URL, into model: VoiceModel) throws -> String {
        guard let architecture = model.architecture, let directory = voicesDirectory(of: model),
            isDownloaded(model)
        else {
            throw SpeechModelImportError.notASpeechModel(model.id)
        }
        try SpeechModelFolder.validateVoice(at: file, architecture: architecture)
        let name = SpeechModelFolder.voiceName(
            for: file.lastPathComponent, existing: voices(of: model))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: file, to: directory.appendingPathComponent("\(name).json"))
        try recordCustomVoices(recordedCustomVoices(of: model) + [name], of: model)
        Log.info("Added voice \(name) to \(model.id)")
        return name
    }

    /// Deletes a voice the user added.
    ///
    /// - Throws: ``SpeechModelImportError/notACustomVoice(_:)`` for a voice that came with
    ///   the model.
    public func deleteVoice(_ voice: String, of model: VoiceModel) throws {
        let recorded = recordedCustomVoices(of: model)
        guard recorded.contains(voice), let directory = voicesDirectory(of: model) else {
            throw SpeechModelImportError.notACustomVoice(voice)
        }
        let file = directory.appendingPathComponent("\(voice).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try recordCustomVoices(recorded.filter { $0 != voice }, of: model)
        Log.info("Deleted voice \(voice) of \(model.id)")
    }

    private func voicesDirectory(of model: VoiceModel) -> URL? {
        guard model.kind == .textToSpeech, let architecture = model.architecture else {
            return nil
        }
        return directory(for: model).appendingPathComponent(
            SpeechModelFolder.voicesDirectory(for: architecture), isDirectory: true)
    }

    private func recordedCustomVoices(of model: VoiceModel) -> [String] {
        let file = directory(for: model).appendingPathComponent(Self.customVoicesName)
        guard let data = try? Data(contentsOf: file),
            let voices = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return voices
    }

    private func recordCustomVoices(_ voices: [String], of model: VoiceModel) throws {
        let file = directory(for: model).appendingPathComponent(Self.customVoicesName)
        try JSONEncoder().encode(voices).write(to: file, options: .atomic)
    }
}
