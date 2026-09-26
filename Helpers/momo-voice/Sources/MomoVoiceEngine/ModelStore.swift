@preconcurrency import AudioCommon
import Foundation
import MomoVoiceCore

/// Where models live on disk, and downloading and deleting them.
///
/// Each model gets its own directory under `~/Library/Application Support/Momo/Models`. A
/// model counts as downloaded only once every file arrived, which a marker file records, so
/// an interrupted download never loads half a model. Downloads resume where they stopped.
public struct ModelStore: Sendable {
    /// The directory that holds every model.
    public let root: URL

    private static let completionMarker = ".momo-complete"

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

    /// The directory of a model.
    public func directory(for model: VoiceModel) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    /// Whether every file of the model is on disk.
    public func isDownloaded(_ model: VoiceModel) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(for: model).appendingPathComponent(Self.completionMarker).path)
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

    /// Deletes a model's files, including a partial download.
    public func delete(_ model: VoiceModel) throws {
        let directory = directory(for: model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
