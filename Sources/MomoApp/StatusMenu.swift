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

        FocusMenu(focus: model.focus)

        Divider()

        CharacterMenu(controller: model.character)

        Divider()

        if let update = model.updates.availableUpdate {
            Button(String(format: L("Update to Momo %@…"), update.version)) {
                model.updates.openReleasePage()
            }
        }
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

/// Starts and stops focus sessions.
private struct FocusMenu: View {
    var focus: FocusController

    var body: some View {
        if let end = focus.endDate {
            Button(
                String(
                    format: L("Stop focus (until %@)"),
                    end.formatted(date: .omitted, time: .shortened))
            ) {
                focus.stop()
            }
        } else {
            Menu(L("Focus")) {
                ForEach([15, 25, 45, 60], id: \.self) { minutes in
                    Button(String(format: L("%lld minutes"), minutes)) {
                        focus.start(minutes: minutes)
                    }
                }
            }
        }
    }
}
