import Foundation
import Testing

@testable import MomoApp

@Suite("Erasing Momo's folders")
struct FolderEraserTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderEraserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    @Test("removes files and subfolders but keeps the folders")
    func removesContents() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try folder("Meetings")
        let artifacts = try folder("Artifacts")
        _ = try write("meeting-1/microphone.wav", in: meetings)
        _ = try write(".hidden", in: meetings)
        _ = try write("2026-10-02/image.png", in: artifacts)

        try FolderEraser.removeContents(of: [meetings, artifacts])

        #expect(try contents(of: meetings).isEmpty)
        #expect(try contents(of: artifacts).isEmpty)
    }

    @Test("leaves files outside the folders alone")
    func keepsOtherFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = try folder("Meetings")
        _ = try write("meeting-1/microphone.wav", in: meetings)
        let store = try write("momo.json", in: root)

        try FolderEraser.removeContents(of: [meetings])

        #expect(FileManager.default.fileExists(atPath: store.path))
    }

    @Test("skips folders that don't exist")
    func skipsMissingFolders() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing", isDirectory: true)
        let artifacts = try folder("Artifacts")
        _ = try write("image.png", in: artifacts)

        try FolderEraser.removeContents(of: [missing, artifacts])

        #expect(try contents(of: artifacts).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("throws when a folder can't be read, after erasing the others")
    func reportsFailures() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let notAFolder = try write("Meetings", in: root)
        let artifacts = try folder("Artifacts")
        _ = try write("image.png", in: artifacts)

        #expect(throws: (any Error).self) {
            try FolderEraser.removeContents(of: [notAFolder, artifacts])
        }
        #expect(try contents(of: artifacts).isEmpty)
    }

    @Test("erases the meeting audio and artifacts folders")
    @MainActor
    func momoFolders() {
        #expect(
            FolderEraser.momoFolders == [AppSettings.meetingsDirectory, ArtifactStore.folder])
    }
}
