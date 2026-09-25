import SwiftUI

/// The app entry point. Momo has no windows of its own besides the notch panel; its controls
/// live in a menu bar extra.
@main
struct MomoApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(controller: appDelegate.controller)
        } label: {
            Image(systemName: "face.smiling")
                .accessibilityLabel(Text("Momo", bundle: .module))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = CharacterController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay out of the Dock and the app switcher, also when launched without an Info.plist
        // (for example with `swift run`).
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}
