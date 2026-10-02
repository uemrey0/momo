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
        if let backup = problem.backup { markReported(backup) }
        run(alert, revealing: problem.backup ?? fileURL)
    }

    /// Tells the user about backups of the data file this app hasn't reported yet, such as
    /// the ones `momo-mcp` makes when it is the first to find the file damaged.
    static func showUnreported(_ backups: [URL]) {
        let reported = Set(UserDefaults.standard.stringArray(forKey: reportedKey) ?? [])
        for backup in backups where !reported.contains(backup.lastPathComponent) {
            markReported(backup)
            let alert = NSAlert()
            alert.alertStyle = .warning
            if backup.lastPathComponent.contains(".corrupt-") {
                alert.messageText = L("Momo couldn't read its saved data")
                alert.informativeText = String(
                    format: L(
                        "The file was damaged, so Momo moved it to %@ and started fresh. Nothing in it was deleted."
                    ), backup.path)
            } else {
                alert.messageText = L("Some saved items couldn't be read")
                alert.informativeText = String(
                    format: L(
                        "Momo left out some damaged items. A copy of the original file is at %@."),
                    backup.path)
            }
            run(alert, revealing: backup)
        }
    }

    /// The backup file names already reported, so each is reported once.
    private static let reportedKey = "reportedStoreBackups"

    private static func markReported(_ backup: URL) {
        var reported = Set(UserDefaults.standard.stringArray(forKey: reportedKey) ?? [])
        reported.insert(backup.lastPathComponent)
        UserDefaults.standard.set(Array(reported).sorted(), forKey: reportedKey)
    }

    private static func run(_ alert: NSAlert, revealing location: URL) {
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Show in Finder"))
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([location])
        }
    }
}
