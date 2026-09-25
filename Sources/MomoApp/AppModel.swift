import AppKit
import Carbon.HIToolbox
import MomoFace
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
    let calendar = CalendarService()
    let focus: FocusController
    let connections: MCPConnections
    @ObservationIgnored private var context: ContextMonitor?
    @ObservationIgnored private(set) var chatPanel: ChatPanelController?
    @ObservationIgnored private(set) var voice: VoiceController?
    @ObservationIgnored private var hotKeys: [GlobalHotKey] = []
    @ObservationIgnored private var onboarding: OnboardingWindowController?

    init() {
        settings = AppSettings()
        store = MomoStore(fileURL: MomoStore.defaultFileURL)
        character = CharacterController()
        assistant = AssistantController(store: store, settings: settings)
        today = TodayModel(store: store)
        notes = NotesModel(store: store)
        focus = FocusController(character: character)
        connections = MCPConnections(settings: settings)
    }

    func start() {
        character.start()
        applyPreferences()
        assistant.character = character
        today.onTaskCompleted = { [weak character] in character?.celebrate() }
        let systemTools = SystemTools.all(calendar: calendar, focus: focus)
        assistant.systemTools = { [weak connections] in systemTools + (connections?.tools ?? []) }
        Task { await connections.refresh() }

        let voice = VoiceController(settings: settings, assistant: assistant, character: character)
        self.voice = voice
        let panel = ChatPanelController(
            assistant: assistant, today: today, notes: notes, state: panelState, voice: voice,
            character: character, openSettings: { [weak self] in self?.openSettings() })
        chatPanel = panel
        voice.showPanel = { [weak panel] in panel?.show(tab: .chat) }
        character.onClick = { [weak panel, weak voice] in
            voice?.stopSpeaking()
            panel?.toggle()
        }
        hotKeys = [
            GlobalHotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak panel] in
                panel?.toggle()
            },
            GlobalHotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey) {
                [weak panel, weak voice] in
                panel?.show(tab: .chat)
                voice?.toggleDictation()
            },
        ].compactMap { $0 }
        voice.startWakeWordIfEnabled()

        let context = ContextMonitor(
            settings: settings, store: store, calendar: calendar, character: character)
        context.openChat = { [weak self] message in
            self?.openChat(tab: .chat)
            if let message { self?.assistant.send(message) }
        }
        context.start()
        self.context = context
        focus.onFinish = { [weak self] _ in self?.character.simulate(.taskCompleted) }

        if !settings.preferences.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Pushes settings that live outside the settings object into the running app.
    func applyPreferences() {
        character.setSleepDelay(minutes: settings.preferences.sleepDelayMinutes)
        character.appearance =
            availableCharacters.first { $0.id == settings.preferences.characterID } ?? .classic
    }

    /// `~/Library/Application Support/Momo/Characters`, for custom character packs.
    static var charactersFolder: URL {
        AppSettings.supportDirectory.appendingPathComponent("Characters", isDirectory: true)
    }

    /// Built-in characters followed by the user's own packs.
    var availableCharacters: [CharacterAppearance] {
        let custom = CharacterAppearance.load(from: Self.charactersFolder)
            .filter { pack in !CharacterAppearance.builtIns.contains { $0.id == pack.id } }
        return CharacterAppearance.builtIns + custom
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
