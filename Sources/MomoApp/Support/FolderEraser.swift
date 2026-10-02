import Foundation

/// Deletes what is inside Momo's own folders, such as kept meeting audio and the images brains
/// made, when the user erases all of Momo's data.
enum FolderEraser {
    /// The folders whose files "Erase all of Momo's data" removes.
    @MainActor
    static var momoFolders: [URL] { [AppSettings.meetingsDirectory, ArtifactStore.folder] }

    /// Removes everything inside each folder and keeps the folders themselves. A folder that
    /// doesn't exist is skipped. Every item is tried; the first failure is thrown at the end.
    static func removeContents(
        of folders: [URL], fileManager: FileManager = .default
    ) throws {
        var firstError: Error?
        for folder in folders {
            let items: [URL]
            do {
                items = try fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch {
                firstError = firstError ?? error
                continue
            }
            for item in items {
                do {
                    try fileManager.removeItem(at: item)
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        if let firstError { throw firstError }
    }
}
