import AppKit
import ApplicationServices
import Foundation
import MomoKit

/// Tells Momo what the user is looking at: the front app and window, the selected text and the
/// current browser tab, so "summarise this" and "translate this" just work.
enum ContextTools {
    /// A browser Momo can ask for its current tab.
    struct Browser: Sendable {
        var name: String
        var bundleIdentifier: String
        /// Safari calls tabs' titles `name` and the active tab `current tab`.
        var isSafari: Bool
    }

    static let browsers = [
        Browser(name: "Safari", bundleIdentifier: "com.apple.Safari", isSafari: true),
        Browser(name: "Google Chrome", bundleIdentifier: "com.google.Chrome", isSafari: false),
        Browser(name: "Arc", bundleIdentifier: "company.thebrowser.Browser", isSafari: false),
        Browser(
            name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac", isSafari: false),
        Browser(name: "Brave Browser", bundleIdentifier: "com.brave.Browser", isSafari: false),
    ]

    /// How the user can let Momo read the selection.
    static let accessibilityHint =
        "Momo can't read the selected text or window title without Accessibility access. The user can allow it in Momo Settings → Permissions."

    static func all() -> [any MomoTool] {
        [getContext()]
    }

    static func getContext() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "get_context",
                description:
                    "See what the user is working on: the frontmost app, its window title, the text they have selected and the current browser tab's title and URL. Call it first when the user says “this”, “summarise this”, “translate this” or “explain this” without giving the text. For a web page's full text, open the URL with a web tool if one is available.",
                activityLabel: L("Looking at what you're doing"))
        ) { _ in
            let front = await MainActor.run { () -> (String, String?, pid_t)? in
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return (app.localizedName ?? "an app", app.bundleIdentifier, app.processIdentifier)
            }
            var lines: [String] = []
            var needsAccessibility = false
            var foundTab = false
            if let (name, bundleIdentifier, processID) = front {
                lines.append("Front app: \(name)")
                if processID == ProcessInfo.processInfo.processIdentifier {
                    lines.append("(Momo itself is in front, so there is nothing else to read.)")
                } else if AXIsProcessTrusted() {
                    let reading = readAccessibility(processID: processID)
                    if let title = reading.windowTitle, !title.isEmpty {
                        lines.append("Window: \(title)")
                    }
                    if let selection = reading.selectedText, !selection.isEmpty {
                        lines.append(
                            "Selected text:\n\(OutputText.truncate(selection, limit: 20_000))")
                    } else {
                        lines.append("Selected text: none")
                    }
                } else {
                    needsAccessibility = true
                }
                if let tab = await browserTab(frontmost: bundleIdentifier) {
                    lines.append(tab)
                    foundTab = true
                }
            } else {
                lines.append("No app is in front.")
            }
            // With a browser tab there is still something useful to answer with.
            if needsAccessibility && !foundTab {
                lines.append("Momo can't read the selected text or window title.")
                throw PermissionRequired(.accessibility, lines.joined(separator: "\n"))
            }
            if needsAccessibility { lines.append(accessibilityHint) }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Accessibility

    /// Reads the focused window's title and the selected text of an app.
    static func readAccessibility(processID: pid_t) -> (windowTitle: String?, selectedText: String?)
    {
        let app = AXUIElementCreateApplication(processID)
        // A hung app must not stall Momo.
        AXUIElementSetMessagingTimeout(app, 1)
        var windowTitle: String?
        if let window: AXUIElement = attribute(kAXFocusedWindowAttribute, of: app) {
            windowTitle = attribute(kAXTitleAttribute, of: window)
        }
        var selectedText: String?
        if let focused: AXUIElement = attribute(kAXFocusedUIElementAttribute, of: app) {
            selectedText = attribute(kAXSelectedTextAttribute, of: focused)
        }
        return (windowTitle, selectedText)
    }

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    // MARK: - Browser

    /// The frontmost browser's tab, or else the first running browser's. Browsers that aren't
    /// running are never asked, because asking would launch them.
    static func browserTab(frontmost bundleIdentifier: String?) async -> String? {
        let running = browsers.filter { AppleScriptRunner.isRunning($0.bundleIdentifier) }
        let ordered =
            running.filter { $0.bundleIdentifier == bundleIdentifier }
            + running.filter { $0.bundleIdentifier != bundleIdentifier }
        for browser in ordered {
            let tab = browser.isSafari ? "current tab" : "active tab"
            let title = browser.isSafari ? "name" : "title"
            let script = """
                tell application id \(AppleScriptText.literal(browser.bundleIdentifier))
                    if (count of windows) is 0 then return ""
                    set theTab to \(tab) of front window
                    return (\(title) of theTab) & linefeed & (URL of theTab)
                end tell
                """
            do {
                let output = try await AppleScriptRunner.run(script, timeout: 5)
                let parts = output.components(separatedBy: "\n")
                guard parts.count >= 2 else { continue }
                let location =
                    browser.bundleIdentifier == bundleIdentifier ? "" : " (in the background)"
                return "\(browser.name) tab\(location): \(parts[0])\nURL: \(parts[1])"
            } catch {
                if browser.bundleIdentifier == bundleIdentifier {
                    return "\(browser.name) tab: unavailable (\(error.localizedDescription))"
                }
            }
        }
        return nil
    }
}
