import Foundation

/// One saved conversation with Momo.
public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// The first thing the user asked, shortened.
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [ConversationMessage]

    public init(
        id: String = UUID().uuidString, title: String? = nil, createdAt: Date = Date(),
        updatedAt: Date = Date(), messages: [ConversationMessage] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.title = title ?? Self.title(for: messages)
    }

    /// The most characters a title keeps.
    public static let titleLength = 80

    /// A title made from the first user message: whitespace collapsed, trimmed, shortened.
    public static func title(for messages: [ConversationMessage]) -> String {
        let first = messages.first { $0.role == .user }?.text ?? ""
        let line = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > titleLength else { return line }
        return String(line.prefix(titleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whether every word of `query` appears in the title or a message, ignoring case and
    /// diacritics ("ayse" finds "Ayşe").
    public func matches(_ query: String) -> Bool {
        let words = Self.folded(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = Self.folded(([title] + messages.map(\.text)).joined(separator: "\n"))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            // Folding keeps the dotless ı; searching for "i" should still find it.
            .replacingOccurrences(of: "ı", with: "i")
    }
}

/// One message of a saved conversation.
public struct ConversationMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// Something went wrong; shown in the chat but never sent to a brain.
        case error
    }

    /// A tool Momo used while answering, as the chat shows it.
    public struct Activity: Codable, Sendable, Hashable {
        public enum State: String, Codable, Sendable {
            case running
            case succeeded
            case failed
        }

        public var toolName: String
        public var state: State

        public init(toolName: String, state: State) {
            self.toolName = toolName
            self.state = state
        }
    }

    public var role: Role
    public var text: String
    public var date: Date
    /// The brain that answered, for assistant messages.
    public var brainName: String?
    public var brainKind: BrainKind?
    public var activities: [Activity]
    /// What the tools were asked and returned, so a reopened conversation keeps its context.
    public var toolRecords: [ToolRecord]

    public init(
        role: Role, text: String, date: Date = Date(), brainName: String? = nil,
        brainKind: BrainKind? = nil, activities: [Activity] = [], toolRecords: [ToolRecord] = []
    ) {
        self.role = role
        self.text = text
        self.date = date
        self.brainName = brainName
        self.brainKind = brainKind
        self.activities = activities
        self.toolRecords = toolRecords
    }

    enum CodingKeys: String, CodingKey {
        case role, text, date, brainName, brainKind, activities, toolRecords
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        brainName = try container.decodeIfPresent(String.self, forKey: .brainName)
        brainKind = try container.decodeIfPresent(BrainKind.self, forKey: .brainKind)
        activities = try container.decodeIfPresent([Activity].self, forKey: .activities) ?? []
        toolRecords =
            try container.decodeIfPresent([ToolRecord].self, forKey: .toolRecords) ?? []
    }
}

/// Saves conversations in a JSON file of their own, newest first, so they can be listed,
/// searched, reopened and continued.
///
/// Writes are atomic, and the file is reloaded when it changed on disk. The oldest
/// conversations are dropped beyond `maximumConversations`, and the oldest messages of a
/// conversation beyond `maximumMessages`.
public actor ConversationStore {
    public nonisolated let fileURL: URL
    public nonisolated let maximumConversations: Int
    public nonisolated let maximumMessages: Int
    private var conversations: [Conversation] = []
    private var loadedModificationDate: Date?

    public init(fileURL: URL, maximumConversations: Int = 200, maximumMessages: Int = 400) {
        self.fileURL = fileURL
        self.maximumConversations = maximumConversations
        self.maximumMessages = maximumMessages
    }

    /// `~/Library/Application Support/Momo/conversations.json`
    public static var defaultFileURL: URL {
        MomoStore.defaultFileURL.deletingLastPathComponent()
            .appendingPathComponent("conversations.json")
    }

    /// All conversations, most recently updated first.
    public func all() -> [Conversation] {
        reloadIfNeeded()
        return conversations
    }

    /// Conversations whose title or messages contain every word of `query`, most recent
    /// first. An empty query returns everything.
    public func search(_ query: String) -> [Conversation] {
        all().filter { $0.matches(query) }
    }

    public func conversation(id: String) -> Conversation? {
        all().first { $0.id == id }
    }

    /// Adds or replaces a conversation and moves it to the top. Conversations without
    /// messages are not saved.
    @discardableResult
    public func save(_ conversation: Conversation) throws -> Conversation {
        reloadIfNeeded()
        var saved = conversation
        saved.messages = Array(saved.messages.suffix(maximumMessages))
        if saved.title.isEmpty { saved.title = Conversation.title(for: saved.messages) }
        var updated = conversations.filter { $0.id != saved.id }
        guard !saved.messages.isEmpty else { return saved }
        updated.insert(saved, at: 0)
        updated.sort { $0.updatedAt > $1.updatedAt }
        try write(Array(updated.prefix(maximumConversations)))
        return saved
    }

    public func delete(id: String) throws {
        reloadIfNeeded()
        guard conversations.contains(where: { $0.id == id }) else { return }
        try write(conversations.filter { $0.id != id })
    }

    /// Deletes every conversation.
    public func deleteAll() throws {
        try write([])
    }

    // MARK: - Persistence

    private func write(_ value: [Conversation]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: fileURL, options: [.atomic])
        conversations = value
        loadedModificationDate = modificationDate()
    }

    private func reloadIfNeeded() {
        let modified = modificationDate()
        guard modified != loadedModificationDate else { return }
        loadedModificationDate = modified
        guard modified != nil, let contents = try? Data(contentsOf: fileURL) else {
            conversations = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Conversation].self, from: contents) {
            conversations = decoded.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate]
            as? Date
    }
}
