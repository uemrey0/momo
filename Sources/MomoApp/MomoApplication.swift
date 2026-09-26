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
            if CommandLine.arguments.contains("--show-settings") { model.openSettings() }
        #endif
    }
}
