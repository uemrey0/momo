import MomoFace
import SwiftUI

/// The menu shown from Momo's menu bar icon.
struct StatusMenu: View {
    @Bindable var controller: CharacterController

    var body: some View {
        Toggle(isOn: $controller.isVisible) {
            Text(
                "Show Momo", bundle: .module,
                comment: "Menu toggle that shows or hides the character")
        }
        Toggle(isOn: $controller.isLifeEnabled) {
            Text(
                "Live on Its Own", bundle: .module,
                comment: "Menu toggle for idle behaviours such as yawning and falling asleep")
        }

        Divider()

        Picker(selection: $controller.mood) {
            ForEach(Mood.allCases) { mood in
                Text(verbatim: mood.displayName).tag(mood)
            }
        } label: {
            Text("Mood", bundle: .module, comment: "Menu title for choosing the character's mood")
        }

        Menu {
            ForEach(FaceEvent.allCases) { event in
                Button {
                    controller.simulate(event)
                } label: {
                    Text(verbatim: event.displayName)
                }
            }
        } label: {
            Text(
                "Try a Reaction", bundle: .module,
                comment: "Menu title for simulating events the character reacts to")
        }

        Picker(selection: $controller.brain) {
            ForEach(BrainSource.allCases) { brain in
                Text(verbatim: brain.displayName).tag(brain)
            }
        } label: {
            Text(
                "Brain", bundle: .module,
                comment: "Menu title for choosing which AI source the eye colour shows")
        }

        Divider()

        Button {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        } label: {
            Text("About Momo", bundle: .module, comment: "Menu item that opens the About panel")
        }
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit Momo", bundle: .module, comment: "Menu item that quits the app")
        }
        .keyboardShortcut("q")
    }
}
