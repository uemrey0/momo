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
    let permissions = PermissionCenter()
    let focus: FocusController
    let connections: MCPConnections
    let updates: UpdateChecker
    let meetings: MeetingController
    @ObservationIgnored let routines: RoutineScheduler
    @ObservationIgnored private var context: ContextMonitor?
    @ObservationIgnored private var meetingDetection: MeetingDetectionMonitor?
    @ObservationIgnored private(set) var chatPanel: ChatPanelController?
    @ObservationIgnored private(set) var voice: VoiceController?
    @ObservationIgnored private var hotKeys: [GlobalHotKey] = []
    @ObservationIgnored private var onboarding: OnboardingWindowController?
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(model: self)
    /// Which Settings pane is showing.
    let settingsNavigation = SettingsNavigation()

    init() {
        settings = AppSettings()
        store = MomoStore(fileURL: MomoStore.defaultFileURL)
        character = CharacterController()
        assistant = AssistantController(
            store: store, settings: settings,
            conversationStore: ConversationStore(fileURL: ConversationStore.defaultFileURL))
        today = TodayModel(store: store)
        notes = NotesModel(store: store)
        focus = FocusController(character: character)
        connections = MCPConnections(settings: settings)
        updates = UpdateChecker(settings: settings)
        routines = RoutineScheduler(store: store, assistant: assistant)
        meetings = MeetingController(
            store: store, settings: settings, calendar: calendar, assistant: assistant,
            character: character)
    }

    func start() {
        character.start()
        applyPreferences()
        assistant.character = character
        today.onTaskCompleted = { [weak character] in character?.celebrate() }
        let systemTools = SystemTools.all(calendar: calendar, focus: focus) + MacTools.all()
        assistant.systemTools = { [weak connections, weak meetings] in
            systemTools + (meetings.map { MeetingTools.all(controller: $0) } ?? [])
                + (connections?.tools ?? [])
        }
        meetings.start()
        Task { await connections.refresh() }

        let voice = VoiceController(settings: settings, assistant: assistant, character: character)
        self.voice = voice
        let panel = ChatPanelController(
            assistant: assistant, today: today, notes: notes, meetings: meetings,
            state: panelState, voice: voice, character: character,
            openSettings: { [weak self] in self?.openSettings($0) },
            openPermissions: { [weak self] in self?.openPermissions($0) })
        chatPanel = panel
        meetings.showMeetings = { [weak panel] in panel?.show(tab: .meetings) }
        panel.hasMeetingQuestion = { [weak meetings] in
            meetings?.startPrompt != nil || meetings?.summaryConsent != nil
        }
        voice.isTakingMeetingNotes = { [weak meetings] in meetings?.isRecording ?? false }
        meetings.onRecordingChanged = { [weak voice] in voice?.meetingNotesChanged() }
        voice.showPanel = { [weak panel] in panel?.show(tab: .chat) }
        voice.isPanelVisible = { [weak panel] in panel?.isVisible ?? false }
        voice.openSettings = { [weak self] in self?.openSettings($0) }
        voice.openPermissions = { [weak self] in self?.openPermissions($0) }
        panel.onShow = { [weak voice] in voice?.chatPanelDidOpen() }
        let bubble = VoiceBubbleController(
            voice: voice, assistant: assistant, character: character,
            openChat: { [weak voice] in voice?.openChatFromBubble() })
        bubble.onCancel = { [weak voice] in voice?.cancelVoiceSession() }
        voice.bubble = bubble
        character.onClick = { [weak panel, weak voice] in
            voice?.stopSpeaking()
            panel?.toggle()
        }
        character.onMenuItem = { [weak self] item in
            guard let self else { return }
            switch item {
            case .talk: openChat(tab: .chat)
            case .today: openChat(tab: .today)
            case .notes: openChat(tab: .notes)
            case .meetings: openChat(tab: .meetings)
            case .stopMeeting: meetings.stop()
            case .setUpAI: openSettings(.ai)
            case .settings: openSettings()
            case .hide: character.isVisible = false
            }
        }
        character.needsAISetup = { [weak self] in self?.hasReadyBrain == false }
        Task { await assistant.refreshProviders() }
        hotKeys = [
            GlobalHotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak panel] in
                panel?.toggle()
            },
            GlobalHotKey(
                keyCode: kVK_Space, modifiers: optionKey | shiftKey,
                action: { [weak voice] in voice?.shortcutPressed() },
                released: { [weak voice] in voice?.shortcutReleased() }),
        ].compactMap { $0 }
        voice.startWakeWordIfEnabled()

        let context = ContextMonitor(
            settings: settings, store: store, calendar: calendar, character: character)
        context.openChat = { [weak self] message in
            self?.openChat(tab: .chat)
            if let message { self?.assistant.send(message) }
        }
        context.openMeetings = { [weak self] in self?.openChat(tab: .meetings) }
        context.takeMeetingNotes = { [weak meetings] in
            guard let meetings else { return }
            Task { await meetings.requestStart(event: meetings.offer?.event) }
        }
        context.start()
        self.context = context

        let detection = MeetingDetectionMonitor(
            settings: settings, calendar: calendar, meetings: meetings)
        detection.isMomoListening = { [weak voice] in voice?.usesMicrophone ?? false }
        detection.notify = { [weak context] offer in
            context?.notifyMeetingOffer(
                id: offer.key, title: L("Should I take notes?"),
                body: offer.event.map {
                    String(
                        format: L("“%@” seems to have started in %@."), $0.title, offer.app.name)
                } ?? String(format: L("A call seems to have started in %@."), offer.app.name))
        }
        detection.start()
        meetingDetection = detection
        routines.notify = { [weak context] id, title, body in
            context?.notifyOpeningChat(id: id, title: title, body: body)
        }
        routines.start()
        focus.onFinish = { [weak self] _ in self?.character.simulate(.taskCompleted) }

        updates.checkIfDue()
        if !settings.preferences.hasCompletedOnboarding {
            showOnboarding()
        }
    }

    /// Pushes settings that live outside the settings object into the running app.
    func applyPreferences() {
        character.setSleepDelay(minutes: settings.preferences.sleepDelayMinutes)
        CapturePrivacy.hidesWindows = settings.preferences.hidesFromScreenCapture
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

    /// Opens Settings, on `pane` if given.
    func openSettings(_ pane: SettingsPane? = nil) {
        if let pane { settingsNavigation.pane = pane }
        chatPanel?.hide()
        settingsWindow.show()
    }

    /// Opens Settings on the Permissions pane, highlighting `permission` if given.
    func openPermissions(_ permission: MacPermission? = nil) {
        settingsNavigation.show(.permissions, highlighting: permission?.anchor)
        chatPanel?.hide()
        settingsWindow.show()
    }

    /// Whether at least one brain is ready to answer. `nil` until the brains were checked.
    var hasReadyBrain: Bool? {
        let statuses = assistant.providerStatuses
        return statuses.isEmpty ? nil : statuses.contains { $0.availability.isReady }
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
