import Foundation
import MomoBrain
import MomoFace
import MomoKit
import Observation

/// A message shown in the chat.
struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case error
    }

    let id = UUID()
    var role: Role
    var text: String
    var brainName: String?
    var brainKind: BrainKind?
    var activities: [ToolActivity] = []
    var isStreaming = false
    /// What the tools of an answer were asked and returned, kept for follow-up questions.
    var toolRecords: [ToolRecord] = []
    var date = Date()
}

extension ChatMessage {
    /// A message restored from a saved conversation.
    init(stored: ConversationMessage) {
        let role: Role =
            switch stored.role {
            case .user: .user
            case .assistant: .assistant
            case .error: .error
            }
        self.init(
            role: role, text: stored.text, brainName: stored.brainName,
            brainKind: stored.brainKind,
            activities: stored.activities.map { activity in
                let state: ToolActivity.State =
                    switch activity.state {
                    case .running: .running
                    case .succeeded: .succeeded
                    case .failed: .failed
                    }
                return ToolActivity(toolName: activity.toolName, state: state)
            },
            toolRecords: stored.toolRecords, date: stored.date)
    }

    /// The message as it is saved. A tool still running when it was saved counts as failed.
    var stored: ConversationMessage {
        let role: ConversationMessage.Role =
            switch role {
            case .user: .user
            case .assistant: .assistant
            case .error: .error
            }
        return ConversationMessage(
            role: role, text: text, date: date, brainName: brainName, brainKind: brainKind,
            activities: activities.map { activity in
                let state: ConversationMessage.Activity.State =
                    switch activity.state {
                    case .running, .failed: .failed
                    case .succeeded: .succeeded
                    }
                return ConversationMessage.Activity(toolName: activity.toolName, state: state)
            },
            toolRecords: toolRecords)
    }

    /// The message as history for a brain; errors are never sent.
    var turn: ChatTurn? {
        switch role {
        case .user: ChatTurn(role: .user, text: text)
        case .assistant: ChatTurn(role: .assistant, text: text, toolRecords: toolRecords)
        case .error: nil
        }
    }
}

/// A tool Momo used while answering.
struct ToolActivity: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case succeeded
        case failed
    }

    let id = UUID()
    var toolName: String
    var state: State
    /// The label the tool describes itself with, if it has one.
    var customLabel: String?

    var label: String { customLabel ?? ToolActivity.label(for: toolName) }

    static func label(for name: String) -> String {
        switch name {
        case "add_task": L("Adding a task", comment: "Tool activity")
        case "list_tasks": L("Checking your tasks", comment: "Tool activity")
        case "complete_task": L("Completing a task", comment: "Tool activity")
        case "update_task": L("Updating a task", comment: "Tool activity")
        case "delete_task": L("Deleting a task", comment: "Tool activity")
        case "add_note": L("Saving a note", comment: "Tool activity")
        case "search_notes": L("Searching your notes", comment: "Tool activity")
        case "append_to_note": L("Updating a note", comment: "Tool activity")
        case "delete_note": L("Deleting a note", comment: "Tool activity")
        case "log_habit": L("Logging a habit", comment: "Tool activity")
        case "list_habits": L("Checking your habits", comment: "Tool activity")
        case "remember": L("Remembering", comment: "Tool activity")
        case "list_memories": L("Checking what I remember", comment: "Tool activity")
        case "forget": L("Forgetting", comment: "Tool activity")
        case "current_time": L("Checking the time", comment: "Tool activity")
        case "calendar_events": L("Looking at your calendar", comment: "Tool activity")
        case "add_calendar_event": L("Adding a calendar event", comment: "Tool activity")
        case "open_app": L("Opening an app", comment: "Tool activity")
        case "open_url": L("Opening a link", comment: "Tool activity")
        case "run_shortcut": L("Running a shortcut", comment: "Tool activity")
        case "read_screen": L("Reading your screen", comment: "Tool activity")
        case "start_focus": L("Starting a focus session", comment: "Tool activity")
        case "get_clipboard": L("Reading the clipboard", comment: "Tool activity")
        default: String(format: L("Using %@", comment: "Tool activity for other tools"), name)
        }
    }
}

/// Momo asking whether to use a remote brain.
struct ConsentPrompt: Identifiable, Equatable {
    let id = UUID()
    var brain: ProviderInfo
    var reason: RoutingReason
    var masksData: Bool

    var explanation: String {
        switch reason {
        case .difficultRequest:
            L("This looks like a bigger job than my on-device brain handles well.")
        case .tooLongForLocal:
            L("This is too long for my on-device brain.")
        case .noLocalBrain:
            L("I don't have an on-device brain available right now.")
        case .userChoice:
            L("You picked this brain for our conversation.")
        default:
            L("This request would go to a remote brain.")
        }
    }
}

/// Momo asking before an action that needs confirmation.
struct ConfirmationPrompt: Identifiable, Equatable {
    let id = UUID()
    var summary: String
}

/// A request that left the Mac, for the privacy log.
struct OutboundRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var brainName: String
    var characters: Int
    var masked: Bool
}

/// A brain and whether it is ready, for the brain picker and settings.
struct ProviderStatus: Identifiable, Equatable {
    var info: ProviderInfo
    var availability: ProviderAvailability
    var id: String { info.id }
}

/// Runs conversations from the chat panel and keeps the character in sync.
@MainActor
@Observable
final class AssistantController {
    var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isBusy = false
    private(set) var consentPrompt: ConsentPrompt?
    private(set) var confirmationPrompt: ConfirmationPrompt?
    private(set) var providerStatuses: [ProviderStatus] = []
    private(set) var outboundLog: [OutboundRecord] = []
    /// A brain the user picked for this conversation, or `nil` for automatic routing.
    var forcedProviderID: String? {
        didSet {
            let id = forcedProviderID
            Task { await assistant.setForcedProvider(id) }
        }
    }

    let store: MomoStore
    let settings: AppSettings
    /// Where conversations are saved; `nil` keeps them in memory only.
    @ObservationIgnored let conversationStore: ConversationStore?
    /// The saved conversation the chat shows, once it has been saved.
    private(set) var conversationID: String?
    /// Increases whenever saved conversations change, so lists of them can reload.
    private(set) var conversationsVersion = 0
    @ObservationIgnored weak var character: CharacterController?
    /// Extra tools provided by the app (calendar, apps, screen...).
    @ObservationIgnored var systemTools: () -> [any MomoTool] = { [] }
    /// Called with each finished reply, for speaking it aloud.
    @ObservationIgnored var onReply: ((String) -> Void)?

    @ObservationIgnored private let assistant = Assistant()
    /// Labels tools describe themselves with, from the latest configuration.
    @ObservationIgnored private var activityLabels: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Identifies the reply in progress; a stopped or replaced reply no longer touches the chat.
    @ObservationIgnored private var currentRun: UUID?
    @ObservationIgnored private var conversationCreatedAt: Date?
    /// The latest change to the assistant's history, which a new reply waits for.
    @ObservationIgnored private var historyUpdate: Task<Void, Never>?
    /// Saves and deletes run one after another, in order.
    @ObservationIgnored private var persistence: Task<Void, Never>?
    @ObservationIgnored private var consentContinuation: CheckedContinuation<RemoteConsent, Never>?
    @ObservationIgnored private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private static let logKey = "outboundLog"

    init(store: MomoStore, settings: AppSettings, conversationStore: ConversationStore? = nil) {
        self.store = store
        self.settings = settings
        self.conversationStore = conversationStore
        if let data = UserDefaults.standard.data(forKey: Self.logKey),
            let log = try? JSONDecoder().decode([OutboundRecord].self, from: data)
        {
            outboundLog = log
        }
    }

    // MARK: - Conversation

    func send(_ text: String? = nil) {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isBusy else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: message))
        isBusy = true
        character?.showWorking()
        let run = UUID()
        currentRun = run
        task = Task { await self.run(message, id: run) }
    }

    /// Stops the reply in progress at once: the chat is free again right away, and whatever
    /// the brain was doing is cancelled in the background.
    func stop() {
        task?.cancel()
        task = nil
        answerConsent(.cancel)
        answerConfirmation(false)
        guard isBusy else { return }
        currentRun = nil
        isBusy = false
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            for step in messages[index].activities.indices
            where messages[index].activities[step].state == .running {
                messages[index].activities[step].state = .failed
            }
        }
        character?.showIdle()
        saveConversation()
    }

    func newConversation() {
        stop()
        messages = []
        conversationID = nil
        conversationCreatedAt = nil
        forcedProviderID = nil
        let assistant = assistant
        historyUpdate = Task { await assistant.reset() }
    }

    // MARK: - Saved conversations

    /// Reopens a saved conversation so it can be continued, with any brain.
    func openConversation(_ conversation: Conversation) {
        stop()
        messages = conversation.messages.map(ChatMessage.init(stored:))
        conversationID = conversation.id
        conversationCreatedAt = conversation.createdAt
        forcedProviderID = nil
        let turns = messages.compactMap(\.turn)
        let assistant = assistant
        historyUpdate = Task { await assistant.restore(history: turns) }
    }

    /// Saved conversations matching `query`, most recent first.
    func conversations(matching query: String) async -> [Conversation] {
        guard let conversationStore else { return [] }
        await persistence?.value
        return await conversationStore.search(query)
    }

    func deleteConversation(id: String) {
        if id == conversationID { newConversation() }
        persist { try await $0.delete(id: id) }
    }

    /// Deletes every saved conversation and starts a new one.
    func eraseConversations() {
        newConversation()
        persist { try await $0.deleteAll() }
    }

    /// Saves the conversation the chat shows, once it has a user message.
    private func saveConversation() {
        guard conversationStore != nil, messages.contains(where: { $0.role == .user }) else {
            return
        }
        let id = conversationID ?? UUID().uuidString
        conversationID = id
        let createdAt = conversationCreatedAt ?? messages.first?.date ?? Date()
        conversationCreatedAt = createdAt
        let conversation = Conversation(
            id: id, createdAt: createdAt, updatedAt: Date(), messages: messages.map(\.stored))
        persist { try await $0.save(conversation) }
    }

    private func persist(_ change: @escaping @Sendable (ConversationStore) async throws -> Void) {
        guard let conversationStore else { return }
        let previous = persistence
        persistence = Task {
            await previous?.value
            try? await change(conversationStore)
            conversationsVersion += 1
        }
    }

    // MARK: - Replies

    private func run(_ message: String, id run: UUID) async {
        await historyUpdate?.value
        let configuration = await makeConfiguration()
        guard currentRun == run else { return }
        activityLabels = Dictionary(
            configuration.toolbox.definitions.compactMap { definition in
                definition.activityLabel.map { (definition.name, $0) }
            },
            uniquingKeysWith: { first, _ in first })
        var replyID: UUID?
        var reply = ""
        /// Changes the reply's message, unless the reply was stopped or replaced meanwhile.
        func update(_ change: (inout ChatMessage) -> Void) {
            guard currentRun == run, let replyID,
                let index = messages.firstIndex(where: { $0.id == replyID })
            else { return }
            change(&messages[index])
        }
        do {
            let stream = await assistant.reply(
                to: message, configuration: configuration,
                consent: { [weak self] brain, reason, masked in
                    await self?.askConsent(brain: brain, reason: reason, masked: masked) ?? .cancel
                },
                confirm: { [weak self] request in
                    await self?.askConfirmation(request.summary) ?? false
                })
            for try await event in stream {
                guard currentRun == run else { return }
                switch event {
                case .brainSelected(let brain, _):
                    let answer = ChatMessage(
                        role: .assistant, text: "", brainName: brain.name,
                        brainKind: brain.kind, isStreaming: true)
                    messages.append(answer)
                    replyID = answer.id
                    character?.showBrain(brain.kind)
                    if brain.kind.isRemote { record(brain: brain, message: message, configuration) }
                case .text(let chunk):
                    if reply.isEmpty { character?.showSpeaking() }
                    reply += chunk
                    update { $0.text += chunk }
                case .toolStarted(let name):
                    update {
                        $0.activities.append(
                            ToolActivity(
                                toolName: name, state: .running,
                                customLabel: activityLabels[name]))
                    }
                case .toolFinished(let name, let succeeded):
                    update { answer in
                        guard
                            let activity = answer.activities.lastIndex(where: {
                                $0.toolName == name && $0.state == .running
                            })
                        else { return }
                        answer.activities[activity].state = succeeded ? .succeeded : .failed
                    }
                    if succeeded, ["add_task", "complete_task", "log_habit"].contains(name) {
                        character?.celebrate()
                    }
                }
            }
            guard currentRun == run, !Task.isCancelled else { return }
            await attachToolRecords(to: update)
            guard currentRun == run else { return }
            update { $0.isStreaming = false }
            if replyID == nil {
                character?.showIdle()
            } else {
                character?.showDone()
                if !reply.isEmpty { onReply?(reply) }
            }
        } catch {
            guard currentRun == run, !(error is CancellationError) else { return }
            await attachToolRecords(to: update)
            guard currentRun == run else { return }
            update { $0.isStreaming = false }
            messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            character?.showTrouble()
        }
        isBusy = false
        task = nil
        currentRun = nil
        saveConversation()
    }

    /// Copies the tool records of the reply that just ended from the assistant's history.
    private func attachToolRecords(to update: ((inout ChatMessage) -> Void) -> Void) async {
        guard let last = await assistant.history.last, last.role == .assistant,
            !last.toolRecords.isEmpty
        else { return }
        update { $0.toolRecords = last.toolRecords }
    }

    private func makeConfiguration() async -> Assistant.Configuration {
        let preferences = settings.preferences
        let providers = BrainCatalog.providers(
            settings: preferences.brains, keys: settings.keys,
            mcpServerPath: AppSettings.mcpServerPath, workingDirectory: AppSettings.cliWorkspace)
        let memories = await store.memories()
        return Assistant.Configuration(
            providers: providers,
            toolbox: Toolbox(StoreTools.all(store: store) + systemTools()),
            policy: preferences.brains.policy,
            masksPersonalData: preferences.brains.masksPersonalData,
            systemPrompt: SystemPrompt.make(
                memories: memories, languageName: preferredLanguageName,
                personality: preferences.personality.instruction))
    }

    // MARK: - Prompts

    private func askConsent(
        brain: ProviderInfo, reason: RoutingReason, masked: Bool
    ) async
        -> RemoteConsent
    {
        character?.showCurious()
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            consentPrompt = ConsentPrompt(brain: brain, reason: reason, masksData: masked)
        }
    }

    func answerConsent(_ answer: RemoteConsent) {
        consentPrompt = nil
        consentContinuation?.resume(returning: answer)
        consentContinuation = nil
        if answer != .cancel { character?.showWorking() }
    }

    private func askConfirmation(_ summary: String) async -> Bool {
        character?.showCurious()
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            confirmationPrompt = ConfirmationPrompt(summary: summary)
        }
    }

    func answerConfirmation(_ approved: Bool) {
        confirmationPrompt = nil
        confirmationContinuation?.resume(returning: approved)
        confirmationContinuation = nil
    }

    // MARK: - Brains

    /// Checks which brains are ready.
    func refreshProviders() async {
        let providers = BrainCatalog.providers(
            settings: settings.preferences.brains, keys: settings.keys,
            mcpServerPath: AppSettings.mcpServerPath, workingDirectory: AppSettings.cliWorkspace)
        var statuses: [ProviderStatus] = []
        for provider in providers {
            statuses.append(
                ProviderStatus(info: provider.info, availability: await provider.availability()))
        }
        providerStatuses = statuses
    }

    // MARK: - Privacy log

    private func record(
        brain: ProviderInfo, message: String, _ configuration: Assistant.Configuration
    ) {
        outboundLog.insert(
            OutboundRecord(
                date: Date(), brainName: brain.name,
                characters: configuration.systemPrompt.count + message.count,
                masked: configuration.masksPersonalData),
            at: 0)
        outboundLog = Array(outboundLog.prefix(100))
        if let data = try? JSONEncoder().encode(outboundLog) {
            UserDefaults.standard.set(data, forKey: Self.logKey)
        }
    }

    func clearOutboundLog() {
        outboundLog = []
        UserDefaults.standard.removeObject(forKey: Self.logKey)
    }
}
