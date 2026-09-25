import AppKit
import Carbon.HIToolbox
import MomoKit
import Observation

/// Owns Momo's long-lived objects and connects them.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let store: MomoStore
    let character: CharacterController
    let assistant: AssistantController
    let today: TodayModel
    let notes: NotesModel
    let panelState = PanelState()
    @ObservationIgnored private(set) var chatPanel: ChatPanelController?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var onboarding: OnboardingWindowController?

    init() {
        settings = AppSettings()
        store = MomoStore(fileURL: MomoStore.defaultFileURL)
        character = CharacterController()
        assistant = AssistantController(store: store, settings: settings)
        today = TodayModel(store: store)
        notes = NotesModel(store: store)
    }

    func start() {
        character.start()
        applyPreferences()
        assistant.character = character
        today.onTaskCompleted = { [weak character] in character?.celebrate() }

        let panel = ChatPanelController(
            assistant: assistant, today: today, notes: notes, state: panelState,
            character: character, openSettings: { [weak self] in self?.openSettings() })
        chatPanel = panel
        character.onClick = { [weak panel] in panel?.toggle() }
        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak panel] in
            panel?.toggle()
        }

        if !settings.preferences.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Pushes settings that live outside the settings object into the running app.
    func applyPreferences() {
        character.setSleepDelay(minutes: settings.preferences.sleepDelayMinutes)
    }

    func openChat(tab: PanelTab? = nil) {
        chatPanel?.show(tab: tab)
    }

    func openSettings() {
        chatPanel?.hide()
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func showOnboarding() {
        let controller = onboarding ?? OnboardingWindowController(model: self)
        onboarding = controller
        controller.show()
    }

    func finishOnboarding() {
        settings.preferences.hasCompletedOnboarding = true
        onboarding?.close()
        onboarding = nil
        character.showDone()
        openChat(tab: .chat)
    }
}
