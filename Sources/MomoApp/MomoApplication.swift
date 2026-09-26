import SwiftUI

/// The app entry point. Momo lives in the notch and the menu bar; its Settings and welcome
/// windows are managed by AppKit controllers (see `SettingsWindowController`).
@main
struct MomoApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: appDelegate.model)
        } label: {
            Image(systemName: "face.smiling")
                .accessibilityLabel(Text("Momo", bundle: .module))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay out of the Dock and the app switcher, also when launched without an Info.plist
        // (for example with `swift run`).
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
            if Snapshots.renderIfRequested() || HeadlessAsk.runIfRequested() { return }
        #endif
        model.start()
        #if DEBUG
            let arguments = CommandLine.arguments
            if arguments.contains("--show-settings") { model.openSettings() }
            // `--show-panel today` opens the panel on a tab; `--show-panel notes,chat` switches
            // between tabs every two seconds, for checking how the panel resizes.
            if let index = arguments.firstIndex(of: "--show-panel") {
                let names = index + 1 < arguments.count ? arguments[index + 1] : "chat"
                let tabs = names.split(separator: ",").compactMap { PanelTab(rawValue: String($0)) }
                for (step, tab) in tabs.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(step) * 2) {
                        self.model.openChat(tab: tab)
                    }
                }
            }
            // `--show-setup ollama` opens the AI page with that option's setup sheet.
            if let index = arguments.firstIndex(of: "--show-setup"), index + 1 < arguments.count,
                let option = BrainOption(rawValue: arguments[index + 1])
            {
                model.settingsNavigation.setupOption = option
                model.openSettings(.ai)
            }
        #endif
    }
}
