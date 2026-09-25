import MomoFace
import SwiftUI

/// The menu shown from Momo's menu bar icon.
struct StatusMenu: View {
    var model: AppModel

    var body: some View {
        Button(L("Talk to Momo")) { model.openChat(tab: .chat) }
            .keyboardShortcut(" ", modifiers: .option)
        Button(L("Today")) { model.openChat(tab: .today) }
        Button(L("Notes")) { model.openChat(tab: .notes) }

        Divider()

        CharacterMenu(controller: model.character)

        Divider()

        Button(L("Settings…")) { model.openSettings() }
            .keyboardShortcut(",")
        Button(L("About Momo")) {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Button(L("Quit Momo")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Controls for the character itself.
private struct CharacterMenu: View {
    @Bindable var controller: CharacterController

    var body: some View {
        Menu(L("Character")) {
            Toggle(L("Show Momo"), isOn: $controller.isVisible)
            Toggle(L("Live on Its Own"), isOn: $controller.isLifeEnabled)
            Divider()
            Picker(L("Mood"), selection: $controller.mood) {
                ForEach(Mood.allCases) { mood in
                    Text(verbatim: mood.displayName).tag(mood)
                }
            }
            Menu(L("Try a Reaction")) {
                ForEach(FaceEvent.allCases) { event in
                    Button(event.displayName) { controller.simulate(event) }
                }
            }
            Picker(L("Brain"), selection: $controller.brain) {
                ForEach(BrainSource.allCases) { brain in
                    Text(verbatim: brain.displayName).tag(brain)
                }
            }
        }
    }
}
