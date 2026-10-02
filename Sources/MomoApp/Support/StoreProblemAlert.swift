import AppKit
import MomoKit

/// Tells the user when Momo couldn't use a data file as it was, and where the backup is.
@MainActor
enum StoreProblemAlert {
    static func show(_ problem: StoreProblem, fileURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch problem {
        case .unreadable(let backup?):
            alert.messageText = L("Momo couldn't read its saved data")
            alert.informativeText = String(
                format: L(
                    "The file was damaged, so Momo moved it to %@ and started fresh. Nothing in it was deleted."
                ), backup.path)
        case .unreadable(nil):
            alert.messageText = L("Momo couldn't read its saved data")
            alert.informativeText = String(
                format: L("Momo won't save changes until the file at %@ is fixed or moved."),
                fileURL.path)
        case .skippedItems(let count, let backup?):
            alert.messageText = L("Some saved items couldn't be read")
            alert.informativeText = String(
                format: L("Momo left out %d damaged items. A copy of the original file is at %@."),
                count, backup.path)
        case .skippedItems(_, nil):
            alert.messageText = L("Some saved items couldn't be read")
            alert.informativeText = String(
                format: L("Momo won't save changes until the file at %@ is fixed or moved."),
                fileURL.path)
        case .newerVersion:
            alert.messageText = L("Your data is from a newer Momo")
            alert.informativeText = L(
                "Update Momo to make changes. Until then, Momo only reads your data.")
        }
        alert.addButton(withTitle: L("OK"))
        let location = problem.backup ?? fileURL
        alert.addButton(withTitle: L("Show in Finder"))
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([location])
        }
    }
}
