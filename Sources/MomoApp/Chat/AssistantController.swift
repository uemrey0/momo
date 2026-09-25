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

    var label: String { ToolActivity.label(for: toolName) }

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
    @ObservationIgnored weak var character: CharacterController?
    /// Extra tools provided by the app (calendar, apps, screen...).
    @ObservationIgnored var systemTools: () -> [any MomoTool] = { [] }
    /// Called with each finished reply, for speaking it aloud.
    @ObservationIgnored var onReply: ((String) -> Void)?

    @ObservationIgnored private let assistant = Assistant()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var consentContinuation: CheckedContinuation<RemoteConsent, Never>?
    @ObservationIgnored private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private static let logKey = "outboundLog"

    init(store: MomoStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
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
        task = Task { await run(message) }
    }

    func stop() {
        task?.cancel()
        answerConsent(.cancel)
        answerConfirmation(false)
    }

    func newConversation() {
        stop()
        messages = []
        forcedProviderID = nil
        Task { await assistant.reset() }
    }

    private func run(_ message: String) async {
        let configuration = await makeConfiguration()
        var index: Int?
        var reply = ""
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
                switch event {
                case .brainSelected(let brain, _):
                    messages.append(
                        ChatMessage(
                            role: .assistant, text: "", brainName: brain.name,
                            brainKind: brain.kind, isStreaming: true))
                    index = messages.count - 1
                    character?.showBrain(brain.kind)
                    if brain.kind.isRemote { record(brain: brain, message: message, configuration) }
                case .text(let chunk):
                    guard let index else { continue }
                    if reply.isEmpty { character?.showSpeaking() }
                    reply += chunk
                    messages[index].text += chunk
                case .toolStarted(let name):
                    guard let index else { continue }
                    messages[index].activities.append(ToolActivity(toolName: name, state: .running))
                case .toolFinished(let name, let succeeded):
                    guard let index,
                        let activity = messages[index].activities.lastIndex(where: {
                            $0.toolName == name && $0.state == .running
                        })
                    else { continue }
                    messages[index].activities[activity].state = succeeded ? .succeeded : .failed
                    if succeeded, ["add_task", "complete_task", "log_habit"].contains(name) {
                        character?.celebrate()
                    }
                }
            }
            if let index { messages[index].isStreaming = false }
            if index == nil {
                character?.showIdle()
            } else {
                character?.showDone()
                if !reply.isEmpty { onReply?(reply) }
            }
        } catch is CancellationError {
            if let index { messages[index].isStreaming = false }
            character?.showIdle()
        } catch {
            if let index { messages[index].isStreaming = false }
            messages.append(ChatMessage(role: .error, text: error.localizedDescription))
            character?.showTrouble()
        }
        isBusy = false
        task = nil
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
