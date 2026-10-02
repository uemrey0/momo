import AppKit
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
    /// The global shortcuts for opening Momo and talking to it.
    let shortcuts: ShortcutCenter
    @ObservationIgnored let routines: RoutineScheduler
    @ObservationIgnored private var context: ContextMonitor?
    @ObservationIgnored private var meetingDetection: MeetingDetectionMonitor?
    @ObservationIgnored private(set) var chatPanel: ChatPanelController?
    @ObservationIgnored private(set) var voice: VoiceController?
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
        shortcuts = ShortcutCenter(settings: settings)
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
            openPermissions: { [weak self] in self?.openPermissions($0) },
            requestPermission: { [weak self] in self?.requestPermission($0) })
        chatPanel = panel
        meetings.showMeetings = { [weak panel] in panel?.show(tab: .meetings) }
        panel.hasMeetingQuestion = { [weak meetings] in
            meetings?.startPrompt != nil || meetings?.summaryConsent != nil
        }
        voice.isTakingMeetingNotes = { [weak meetings] in meetings?.isRecording ?? false }
        meetings.onRecordingChanged = { [weak voice] in voice?.meetingNotesChanged() }
        meetings.onDeviceTranscription = { [weak voice] locale in
            voice?.onDeviceTranscription(locale: locale)
        }
        meetings.voiceModelsCanListen = { [weak voice] in
            await voice?.listeningModelsStatus() ?? .unavailable
        }
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
            case .hide:
                character.isVisible = false
                settings.preferences.showsCharacter = false
            }
        }
        character.needsAISetup = { [weak self] in self?.hasReadyBrain == false }
        Task { await assistant.refreshProviders() }
        shortcuts.setHandler(for: .openPanel) { [weak panel] in panel?.toggle() }
        shortcuts.setHandler(
            for: .talk, pressed: { [weak voice] in voice?.shortcutPressed() },
            released: { [weak voice] in voice?.shortcutReleased() })
        shortcuts.apply()
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

        updates.start()
        if !settings.preferences.hasCompletedOnboarding {
            showOnboarding()
        }
        watchStoreProblems()
    }

    /// Tells the user once about each problem reading the data files, now or when the data
    /// file changes later.
    private func watchStoreProblems() {
        let store = store
        let conversations = assistant.conversationStore
        Task { [weak self] in
            if let conversations, let problem = await conversations.problem() {
                StoreProblemAlert.show(problem, fileURL: conversations.fileURL)
            }
            // Backups momo-mcp made, or that an earlier launch didn't get to report. One made
            // just now while loading is reported with its details below.
            let current = await store.problem()?.backup?.lastPathComponent
            StoreProblemAlert.showUnreported(
                store.backups().filter { $0.lastPathComponent != current })
            var reported: StoreProblem?
            for await _ in await store.changes() {
                guard self != nil else { return }
                let problem = await store.problem()
                guard let problem, problem != reported else { continue }
                reported = problem
                StoreProblemAlert.show(problem, fileURL: store.fileURL)
            }
        }
    }

    /// Pushes settings that live outside the settings object into the running app.
    func applyPreferences() {
        character.setSleepDelay(minutes: settings.preferences.sleepDelayMinutes)
        CapturePrivacy.hidesWindows = settings.preferences.hidesFromScreenCapture
        character.appearance =
            availableCharacters.first { $0.id == settings.preferences.characterID } ?? .classic
        character.isVisible = settings.preferences.showsCharacter
        character.isLifeEnabled = settings.preferences.isLifeEnabled
        character.mood = settings.preferences.mood
        character.brain = settings.preferences.brainSource
        shortcuts.apply()
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

    /// Asks macOS for `permission` when it hasn't asked yet; otherwise opens its page in System
    /// Settings, where the user can turn it on.
    func requestPermission(_ permission: MacPermission) {
        Task {
            await permissions.refresh()
            await permissions.request(permission)
        }
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
