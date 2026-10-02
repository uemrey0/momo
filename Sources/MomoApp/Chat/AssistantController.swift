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
    /// Files and images the user attached, sent along with the message.
    var attachments: [ChatAttachment] = []
    /// Attachments of a reopened conversation: only their names were saved.
    var savedAttachments: [ConversationMessage.AttachmentInfo] = []
    /// The answer in the order it happened: what Momo said between its steps.
    var parts: [ReplyPart] = []
    /// Images and files Momo made while answering.
    var artifacts: [ChatArtifact] = []
    /// What went wrong and how to fix it, for error messages.
    var issue: ChatIssue?
    /// When the answer was done, for how long Momo worked.
    var finishedAt: Date?
}

/// One piece of an answer: text Momo said, or a step it took.
enum ReplyPart: Equatable {
    case text(String)
    case step(UUID)
}

extension ChatMessage {
    /// Adds streamed text to the answer, continuing the text after the last step.
    mutating func appendText(_ chunk: String) {
        text += chunk
        if case .text(let current)? = parts.last {
            parts[parts.count - 1] = .text(current + chunk)
        } else {
            parts.append(.text(chunk))
        }
    }

    /// Adds a step Momo started.
    mutating func appendStep(_ activity: ToolActivity) {
        activities.append(activity)
        parts.append(.step(activity.id))
    }

    /// The final answer: what Momo said after its last step. Earlier text was Momo thinking
    /// out loud while it worked.
    var answer: String {
        guard let lastStep = parts.lastIndex(where: { if case .step = $0 { true } else { false } })
        else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let after = parts[(lastStep + 1)...].compactMap { part in
            if case .text(let text) = part { text } else { nil }
        }
        .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard after.isEmpty, !isStreaming else { return after }
        // Some brains say what they'll do and then finish silently, for example after drawing
        // an image; what they said last is then the answer.
        return parts[..<lastStep].reversed().lazy.compactMap { part -> String? in
            guard case .text(let text) = part else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.first ?? ""
    }

    /// Whether Momo took steps or thought out loud before its answer.
    var hasWork: Bool { !activities.isEmpty }

    /// How long Momo worked on the answer.
    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(date) }
    }
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
                return ToolActivity(
                    toolName: activity.toolName, state: state, detail: activity.detail)
            },
            toolRecords: stored.toolRecords, date: stored.date,
            savedAttachments: stored.attachments,
            artifacts: stored.artifacts.map { ChatArtifact(url: URL(fileURLWithPath: $0)) }
                .filter { FileManager.default.fileExists(atPath: $0.url.path) })
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
                return ConversationMessage.Activity(
                    toolName: activity.toolName, state: state, detail: activity.detail)
            },
            toolRecords: toolRecords,
            attachments: savedAttachments
                + attachments.map { .init(name: $0.name, isImage: $0.isImage) },
            artifacts: artifacts.map(\.url.path))
    }

    /// The message as history for a brain; errors are never sent.
    var turn: ChatTurn? {
        switch role {
        case .user:
            ChatTurn(
                role: .user,
                text: savedAttachments.isEmpty
                    ? text
                    : text + "\n\n(Attached earlier, no longer available: "
                        + savedAttachments.map(\.name).joined(separator: ", ") + ")",
                attachments: attachments)
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
    /// The macOS permission the tool was missing, when that is why it failed.
    var missingPermission: MacPermission?
    /// A short hint of what the tool works on, such as a search query or a file name.
    var detail: String?
    var startedAt = Date()
    var finishedAt: Date?

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
        case "add_routine": L("Adding a routine", comment: "Tool activity")
        case "list_routines": L("Checking your routines", comment: "Tool activity")
        case "update_routine": L("Updating a routine", comment: "Tool activity")
        case "delete_routine": L("Deleting a routine", comment: "Tool activity")
        case "list_meetings": L("Checking your meetings", comment: "Tool activity")
        case "get_meeting": L("Reading meeting notes", comment: "Tool activity")
        case "meeting_action_items_to_tasks":
            L("Adding action items as tasks", comment: "Tool activity")
        case "current_time": L("Checking the time", comment: "Tool activity")
        case "calendar_events": L("Looking at your calendar", comment: "Tool activity")
        case "add_calendar_event": L("Adding a calendar event", comment: "Tool activity")
        case "open_app": L("Opening an app", comment: "Tool activity")
        case "open_url": L("Opening a link", comment: "Tool activity")
        case "run_shortcut": L("Running a shortcut", comment: "Tool activity")
        case "read_screen": L("Reading your screen", comment: "Tool activity")
        case "start_focus": L("Starting a focus session", comment: "Tool activity")
        case "get_clipboard": L("Reading the clipboard", comment: "Tool activity")
        case "run_command": L("Running a command", comment: "Tool activity")
        case "generate_image": L("Drawing", comment: "Tool activity")
        case "edit_image": L("Editing a picture", comment: "Tool activity")
        case "get_weather": L("Checking the weather", comment: "Tool activity")
        case "codex_skill": L("Getting ready", comment: "Tool activity")
        // Searches the CLI brains run themselves.
        case "web_search", "google_web_search":
            L("Searching the web", comment: "Tool activity")
        default:
            String(
                format: L("Using %@", comment: "Tool activity for other tools"),
                name.replacingOccurrences(of: "_", with: " "))
        }
    }
}

/// Momo asking whether to use a remote brain.
struct ConsentPrompt: Identifiable, Equatable {
    let id = UUID()
    var brain: ProviderInfo
    var reason: RoutingReason
    var masksData: Bool
    /// The message has images the brain will see; they can't be masked.
    var sendsImages = false

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
        case .imageAttached:
            L("Your message has an image, and my on-device brain can't see images.")
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
    /// The brain or service the request went to.
    var brainName: String
    var characters: Int
    var masked: Bool
    /// Seconds of audio sent, for cloud transcription.
    var audioSeconds: Double?
}

/// Remembers the user's consent for one background job, so it is asked at most once.
private actor ConsentMemory {
    private let ask: RemoteConsentHandler
    private var remembered: RemoteConsent?

    init(ask: @escaping RemoteConsentHandler) {
        self.ask = ask
    }

    func answer(brain: ProviderInfo, reason: RoutingReason, masked: Bool) async -> RemoteConsent {
        if let remembered { return remembered }
        let answer = await ask(brain, reason, masked)
        switch answer {
        // One job counts as one request, so allowing it once allows all of its parts.
        case .allowOnce, .allowForConversation: remembered = .allowOnce
        case .useLocal: remembered = .useLocal
        case .cancel: remembered = .cancel
        }
        return answer
    }
}

/// A brain and whether it is ready, for the brain picker and settings.
struct ProviderStatus: Identifiable, Equatable {
    var info: ProviderInfo
    var availability: ProviderAvailability
    var id: String { info.id }
}

/// What a reply reports while it streams, for speaking it in a live conversation.
enum ReplyStreamEvent: Equatable {
    /// The brain that answers was picked; `isRemote` when it runs off the Mac.
    case brainSelected(name: String, isRemote: Bool)
    case text(String)
    /// A tool started; `label` is its activity label.
    case toolStarted(label: String)
    case toolFinished
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
    /// Files and images waiting to be sent with the next message.
    var pendingAttachments: [ChatAttachment] = []
    /// Attachments still being read, shown as placeholders until they are ready.
    var loadingAttachments: [LoadingAttachment] = []
    /// A short note about attachments, such as a file that couldn't be read.
    var attachmentNotice: String?
    /// Whether the user is choosing files, so the panel stays open meanwhile.
    @ObservationIgnored var isChoosingFiles = false
    /// Whether the message being answered has images.
    @ObservationIgnored private var sendingImages = false
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
    /// Called when a background request needs the user to answer a consent or confirmation
    /// question in the panel.
    @ObservationIgnored var onAttentionNeeded: (() -> Void)?
    /// Whether the current request came from ``sendInBackground(_:completion:)``.
    @ObservationIgnored private(set) var isInBackground = false
    /// Called when a consent or confirmation question appears, for asking it aloud.
    @ObservationIgnored var onPrompt: (() -> Void)?
    /// Called when a request ends, whether it was answered, failed or was cancelled.
    @ObservationIgnored var onRequestFinished: (() -> Void)?
    /// Called when a consent or confirmation question was answered, by voice or a button.
    @ObservationIgnored var onPromptAnswered: (() -> Void)?
    /// Called while a reply streams: its text and tools, for a live conversation.
    @ObservationIgnored var onReplyEvent: ((ReplyStreamEvent) -> Void)?
    /// Why the latest request failed, or `nil` when it didn't.
    @ObservationIgnored private(set) var lastRequestError: String?
    /// What went wrong with the last request, explained, for saying it aloud.
    @ObservationIgnored private(set) var lastRequestIssue: ChatIssue?
    /// The brain that answered the last request.
    @ObservationIgnored private(set) var lastBrainName: String?
    /// Whether the current request is answered in a live voice conversation, which asks the
    /// brain for short spoken replies.
    @ObservationIgnored private var isSpokenRequest = false

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

    /// Sends `text` (or the draft). With `spoken`, the reply is read aloud in a live voice
    /// conversation, so the brain is asked for a short spoken answer.
    func send(_ text: String? = nil, spoken: Bool = false) {
        let message = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !message.isEmpty || !attachments.isEmpty, !isBusy else { return }
        isSpokenRequest = spoken
        lastRequestError = nil
        lastRequestIssue = nil
        draft = ""
        pendingAttachments = []
        attachmentNotice = nil
        sendingImages = attachments.contains(where: \.isImage)
        messages.append(ChatMessage(role: .user, text: message, attachments: attachments))
        isBusy = true
        character?.showWorking()
        let run = UUID()
        currentRun = run
        task = Task { _ = await self.run(message, attachments: attachments, id: run) }
    }

    /// Answers `text` in the chat conversation without opening the panel or speaking, for
    /// routines. Returns `false` without doing anything when Momo is busy; otherwise calls
    /// `completion` with the reply, or `nil` if there was none.
    @discardableResult
    func sendInBackground(_ text: String, completion: @escaping (String?) -> Void) -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isBusy else { return false }
        messages.append(ChatMessage(role: .user, text: message))
        isBusy = true
        isInBackground = true
        isSpokenRequest = false
        lastRequestError = nil
        lastRequestIssue = nil
        sendingImages = false
        character?.showWorking()
        let run = UUID()
        currentRun = run
        task = Task {
            let reply = await self.run(message, attachments: [], id: run)
            // A stopped run must not clear the flag of a newer background request.
            if currentRun == nil || currentRun == run { isInBackground = false }
            completion(reply)
        }
        return true
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
        isInBackground = false
        onRequestFinished?()
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].finishedAt = Date()
            for step in messages[index].activities.indices
            where messages[index].activities[step].state == .running {
                messages[index].activities[step].state = .failed
            }
        }
        character?.showIdle()
        saveConversation()
    }

    /// Asks the last message again, for example after fixing what made it fail. The failed
    /// answer is replaced.
    func retry() {
        guard !isBusy, let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let request = messages[index]
        messages.removeSubrange((index + 1)...)
        isSpokenRequest = false
        lastRequestError = nil
        lastRequestIssue = nil
        attachmentNotice = nil
        sendingImages = request.attachments.contains(where: \.isImage)
        isBusy = true
        character?.showWorking()
        let run = UUID()
        currentRun = run
        task = Task {
            _ = await self.run(request.text, attachments: request.attachments, id: run)
        }
    }

    /// Whether the last message can be asked again.
    var canRetry: Bool {
        !isBusy && messages.last.map { $0.role != .user } == true
            && messages.contains { $0.role == .user }
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

    /// Answers `message` and returns the reply, or `nil` when there was none or the reply was
    /// stopped or replaced.
    private func run(
        _ message: String, attachments: [ChatAttachment], id run: UUID
    ) async -> String? {
        await historyUpdate?.value
        let configuration = await makeConfiguration(for: message)
        guard currentRun == run else { return nil }
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
                to: message, attachments: attachments, configuration: configuration,
                consent: { [weak self] brain, reason, masked in
                    await self?.askConsent(brain: brain, reason: reason, masked: masked) ?? .cancel
                },
                confirm: { [weak self] request in
                    await self?.askConfirmation(Self.confirmationText(for: request)) ?? false
                })
            for try await event in stream {
                guard currentRun == run else { return nil }
                switch event {
                case .brainSelected(let brain, _):
                    let answer = ChatMessage(
                        role: .assistant, text: "", brainName: brain.name,
                        brainKind: brain.kind, isStreaming: true)
                    messages.append(answer)
                    replyID = answer.id
                    character?.showBrain(brain.kind)
                    lastBrainName = brain.name
                    onReplyEvent?(.brainSelected(name: brain.name, isRemote: brain.kind.isRemote))
                    if brain.kind.isRemote {
                        // Attached documents leave the Mac too, so they count.
                        let sent = ChatTurn(role: .user, text: message, attachments: attachments)
                            .context(imagesVisible: brain.supportsImages)
                        record(brain: brain, message: sent, configuration)
                    }
                    if sendingImages && !brain.supportsImages {
                        attachmentNotice = String(
                            format: L("%@ can't see images, so it only got their names."),
                            brain.name)
                    }
                case .text(let chunk):
                    if reply.isEmpty { character?.showSpeaking() }
                    reply += chunk
                    update { $0.appendText(chunk) }
                    onReplyEvent?(.text(chunk))
                case .toolStarted(let name, let detail):
                    let activity = ToolActivity(
                        toolName: name, state: .running, customLabel: activityLabels[name],
                        detail: detail)
                    update { $0.appendStep(activity) }
                    onReplyEvent?(.toolStarted(label: activity.label))
                case .artifact(let artifact):
                    let kept = ArtifactStore.keep(artifact)
                    update { answer in
                        if !answer.artifacts.contains(kept) { answer.artifacts.append(kept) }
                    }
                case .toolFinished(let name, let succeeded, let permission):
                    update { answer in
                        guard
                            let activity = answer.activities.lastIndex(where: {
                                $0.toolName == name && $0.state == .running
                            })
                        else { return }
                        answer.activities[activity].state = succeeded ? .succeeded : .failed
                        answer.activities[activity].missingPermission = permission
                        answer.activities[activity].finishedAt = Date()
                    }
                    onReplyEvent?(.toolFinished)
                    if succeeded, ["add_task", "complete_task", "log_habit"].contains(name) {
                        character?.celebrate()
                    }
                }
            }
            guard currentRun == run, !Task.isCancelled else { return nil }
            await attachToolRecords(to: update)
            guard currentRun == run else { return nil }
            update {
                $0.isStreaming = false
                $0.finishedAt = Date()
            }
            if replyID == nil {
                character?.showIdle()
            } else {
                character?.showDone()
                if !reply.isEmpty, !isInBackground { onReply?(reply) }
            }
        } catch {
            guard currentRun == run, !(error is CancellationError) else { return nil }
            await attachToolRecords(to: update)
            guard currentRun == run else { return nil }
            update {
                $0.isStreaming = false
                $0.finishedAt = Date()
            }
            messages.append(
                ChatMessage(
                    role: .error, text: error.localizedDescription,
                    issue: ChatIssue(error: error)))
            lastRequestError = error.localizedDescription
            lastRequestIssue = ChatIssue(error: error)
            character?.showTrouble()
            reply = ""
        }
        isBusy = false
        task = nil
        currentRun = nil
        saveConversation()
        onRequestFinished?()
        return reply.isEmpty ? nil : reply
    }

    /// Copies the tool records of the reply that just ended from the assistant's history.
    private func attachToolRecords(to update: ((inout ChatMessage) -> Void) -> Void) async {
        guard let last = await assistant.history.last, last.role == .assistant,
            !last.toolRecords.isEmpty
        else { return }
        update { $0.toolRecords = last.toolRecords }
    }

    /// Everything the assistant needs to answer `message`, with the memories related to it.
    private func makeConfiguration(for message: String) async -> Assistant.Configuration {
        let preferences = settings.preferences
        let providers = BrainCatalog.providers(
            settings: preferences.brains, keys: settings.keys,
            mcpServerPath: AppSettings.bridgeRelayPath, workingDirectory: AppSettings.cliWorkspace)
        let memories = await store.memories()
        let webTools = WebTools.all(
            searcher: WebSearcher(braveKey: settings.keys.key(for: WebSearcher.braveKeyID)),
            labels: WebTools.Labels(
                search: L("Searching the web", comment: "Tool activity"),
                read: L("Reading a web page", comment: "Tool activity")))
        let toolbox = Toolbox(
            preferences.abilities.apply(
                to: StoreTools.all(store: store) + webTools + imageTools() + systemTools()))
        return Assistant.Configuration(
            providers: providers,
            toolbox: toolbox,
            policy: preferences.brains.policy,
            masksPersonalData: preferences.brains.masksPersonalData,
            systemPrompt: SystemPrompt.make(
                memories: memories, languageName: preferredLanguageName,
                personality: preferences.personality.instruction, message: message,
                canDraw: toolbox.tool(named: "generate_image") != nil,
                isSpoken: isSpokenRequest),
            prefersSpeed: isSpokenRequest)
    }

    /// The image tools, drawing with the backend the user prefers or the best available one.
    /// Remote backends are never used in local-only mode, and each remote request is logged.
    func imageTools() -> [any MomoTool] {
        let preferences = settings.preferences
        let generator = ImageGenerator(
            backends: ImageBackendCatalog.backends(
                settings: preferences.images, keys: settings.keys,
                workingDirectory: AppSettings.cliWorkspace),
            preferred: preferences.images.preferred, localOnly: preferences.brains.localOnly,
            folder: ArtifactStore.folder,
            recordRemoteRequest: { [weak self] service, characters in
                await self?.recordOutbound(service: service, characters: characters)
            })
        return ImageTools.all(
            generator: generator, activityLabel: ToolActivity.label(for: "generate_image"),
            editActivityLabel: ToolActivity.label(for: "edit_image"))
    }

    // MARK: - Background jobs

    /// A brain for jobs outside the chat, such as meeting summaries: each call answers one
    /// prompt with the given instructions, without tools or history, through a fresh
    /// ``Assistant``, so routing, the local-only lock, consent and personal data masking
    /// apply as in the chat, and remote requests are logged.
    ///
    /// `consent` asks the user; its answer is remembered for every later call of the returned
    /// closure, so one job (a map-reduce summary of several requests) asks at most once.
    func backgroundBrain(consent: @escaping RemoteConsentHandler) -> MeetingSummarizer.Complete {
        let memory = ConsentMemory(ask: consent)
        return { [weak self] instructions, prompt in
            guard let self else { throw CancellationError() }
            return try await self.answerOnce(
                prompt, instructions: instructions,
                consent: { brain, reason, masked in
                    await memory.answer(brain: brain, reason: reason, masked: masked)
                })
        }
    }

    /// How much transcript fits one background request: enough for the smallest ready
    /// on-device brain, so long jobs are split instead of leaving the Mac just for length.
    var backgroundRequestBudget: Int {
        let ready = providerStatuses.filter(\.availability.isReady).map(\.info)
        let local = ready.filter { $0.kind == .local }.map(\.comfortableLength)
        let smallest = local.min() ?? ready.map(\.comfortableLength).min() ?? 24_000
        return min(40_000, max(4_000, smallest * 6 / 10))
    }

    private func answerOnce(
        _ prompt: String, instructions: String, consent: @escaping RemoteConsentHandler
    ) async throws -> String {
        let preferences = settings.preferences
        let configuration = Assistant.Configuration(
            providers: BrainCatalog.providers(
                settings: preferences.brains, keys: settings.keys,
                mcpServerPath: AppSettings.bridgeRelayPath,
                workingDirectory: AppSettings.cliWorkspace),
            toolbox: Toolbox(), policy: preferences.brains.policy,
            masksPersonalData: preferences.brains.masksPersonalData, systemPrompt: instructions)
        let stream = await Assistant().reply(
            to: prompt, configuration: configuration, consent: consent, confirm: { _ in false })
        var reply = ""
        var answered = false
        for try await event in stream {
            switch event {
            case .brainSelected(let brain, _):
                answered = true
                if brain.kind.isRemote { record(brain: brain, message: prompt, configuration) }
            case .text(let chunk):
                reply += chunk
            case .toolStarted, .toolFinished, .artifact:
                break
            }
        }
        guard answered else { throw CancellationError() }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProviderError("The brain gave an empty answer.") }
        return text
    }

    // MARK: - Prompts

    private func askConsent(
        brain: ProviderInfo, reason: RoutingReason, masked: Bool
    ) async
        -> RemoteConsent
    {
        character?.showCurious()
        if isInBackground { onAttentionNeeded?() }
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            consentPrompt = ConsentPrompt(
                brain: brain, reason: reason, masksData: masked,
                sendsImages: sendingImages && brain.supportsImages)
            onPrompt?()
        }
    }

    func answerConsent(_ answer: RemoteConsent) {
        let wasAsking = consentContinuation != nil
        consentPrompt = nil
        consentContinuation?.resume(returning: answer)
        consentContinuation = nil
        if answer != .cancel { character?.showWorking() }
        if wasAsking { onPromptAnswered?() }
    }

    /// What the confirmation shows: the action, and why Momo asks when it usually wouldn't.
    nonisolated static func confirmationText(for request: ToolConfirmationRequest) -> String {
        switch request.reason {
        case .untrustedContent:
            String(
                format: L(
                    "%@\n\nMomo read a web page, file or other outside text during this reply. Check that you asked for this, since that text may be trying to steer Momo."
                ), request.summary)
        case nil:
            request.summary
        }
    }

    private func askConfirmation(_ summary: String) async -> Bool {
        character?.showCurious()
        if isInBackground { onAttentionNeeded?() }
        return await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            confirmationPrompt = ConfirmationPrompt(summary: summary)
            onPrompt?()
        }
    }

    func answerConfirmation(_ approved: Bool) {
        let wasAsking = confirmationContinuation != nil
        confirmationPrompt = nil
        confirmationContinuation?.resume(returning: approved)
        confirmationContinuation = nil
        if wasAsking { onPromptAnswered?() }
    }

    // MARK: - Live conversation

    /// One short sentence Momo can say while the brain works on `turn` ("Takvimine
    /// bakıyorum."), from the fastest ready on-device brain (Apple Intelligence first), or
    /// `nil` when none is ready in time. Nothing leaves the Mac.
    func quickAcknowledgement(for turn: String) async -> String? {
        let ready = Set(
            providerStatuses.filter { $0.availability.isReady && $0.info.kind == .local }
                .map(\.info.id))
        guard !ready.isEmpty else { return nil }
        let providers = BrainCatalog.providers(
            settings: settings.preferences.brains, keys: settings.keys, mcpServerPath: nil,
            workingDirectory: AppSettings.cliWorkspace
        )
        .filter { ready.contains($0.info.id) && $0.info.kind == .local }
        let provider =
            providers.first { $0.info.id == AppleIntelligence.providerID } ?? providers.first
        guard let provider else { return nil }
        return await LiveAcknowledgement.make(for: turn, with: provider)
    }

    // MARK: - Brains

    /// Checks which brains are ready.
    func refreshProviders() async {
        let providers = BrainCatalog.providers(
            settings: settings.preferences.brains, keys: settings.keys,
            mcpServerPath: AppSettings.bridgeRelayPath, workingDirectory: AppSettings.cliWorkspace)
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
        record(
            OutboundRecord(
                date: Date(), brainName: brain.name,
                characters: configuration.systemPrompt.count + message.count,
                masked: configuration.masksPersonalData))
    }

    /// Logs a voice request that left the Mac: text sent to a cloud voice, or audio sent to
    /// a cloud transcription service.
    func recordOutbound(service: String, characters: Int = 0, audioSeconds: Double? = nil) {
        record(
            OutboundRecord(
                date: Date(), brainName: service, characters: characters, masked: false,
                audioSeconds: audioSeconds))
    }

    private func record(_ entry: OutboundRecord) {
        outboundLog.insert(entry, at: 0)
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
