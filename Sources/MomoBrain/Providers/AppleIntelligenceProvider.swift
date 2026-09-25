import Foundation
import MomoKit

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Creates the on-device Apple Intelligence provider when the OS supports it.
public enum AppleIntelligence {
    public static let providerID = "apple"

    /// `nil` before macOS 26 or when the SDK lacks Foundation Models.
    public static func makeProvider() -> (any ChatProvider)? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                return AppleIntelligenceProvider()
            }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)

    /// Answers with Apple's on-device model through the Foundation Models framework.
    ///
    /// Nothing leaves the Mac. The model has a small context window, so only recent turns are
    /// included, and Momo's tools are bridged with dynamic generation schemas.
    @available(macOS 26, *)
    struct AppleIntelligenceProvider: ChatProvider {
        let info = ProviderInfo(
            id: AppleIntelligence.providerID, name: "Apple Intelligence", kind: .local,
            comfortableLength: 6_000)

        func availability() async -> ProviderAvailability {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return .ready
            case .unavailable(.deviceNotEligible):
                return .unavailable("This Mac does not support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled):
                return .unavailable("Turn on Apple Intelligence in System Settings.")
            case .unavailable(.modelNotReady):
                return .unavailable("Apple's model is still downloading. Try again later.")
            case .unavailable:
                return .unavailable("Apple Intelligence is not available right now.")
            }
        }

        func respond(
            to request: ChatRequest, runTool: @escaping ToolRunner
        )
            -> AsyncThrowingStream<ChatEvent, any Error>
        {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await run(request, runTool: runTool, continuation: continuation)
                        continuation.finish()
                    } catch let error as LanguageModelSession.GenerationError {
                        continuation.finish(throwing: ProviderError(Self.describe(error)))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        private func run(
            _ request: ChatRequest, runTool: @escaping ToolRunner,
            continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation
        ) async throws {
            let tools: [any Tool] = try request.tools.map { definition in
                try DynamicTool(definition: definition) { json in
                    let call = ToolCall(
                        id: ShortID.make(), name: definition.name, arguments: json)
                    continuation.yield(.toolStarted(call))
                    let result = await runTool(call)
                    continuation.yield(.toolFinished(result))
                    return result.output
                }
            }
            let session = LanguageModelSession(
                model: .default, tools: tools, instructions: request.systemPrompt)
            let prompt = PromptFlattener.prompt(for: request.turns, budget: 5_000)

            var shown = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                let content = snapshot.content
                if content.hasPrefix(shown) {
                    let delta = String(content.dropFirst(shown.count))
                    if !delta.isEmpty { continuation.yield(.text(delta)) }
                    shown = content
                }
            }
        }

        static func describe(_ error: LanguageModelSession.GenerationError) -> String {
            switch error {
            case .exceededContextWindowSize:
                "That was too long for the on-device model. Try a shorter message or a bigger brain."
            case .guardrailViolation, .refusal:
                "Apple's model declined to answer that."
            case .unsupportedLanguageOrLocale:
                "Apple's model does not support this language yet."
            case .assetsUnavailable:
                "Apple's model is not ready yet."
            case .rateLimited, .concurrentRequests:
                "Apple's model is busy. Try again in a moment."
            default:
                "Apple's model could not answer: \(error.localizedDescription)"
            }
        }
    }

    /// A Foundation Models tool whose arguments are described at runtime.
    @available(macOS 26, *)
    struct DynamicTool: Tool {
        typealias Arguments = GeneratedContent
        typealias Output = String

        let name: String
        let description: String
        let parameters: GenerationSchema
        let handler: @Sendable (String) async -> String

        init(
            definition: ToolDefinition, handler: @escaping @Sendable (String) async -> String
        )
            throws
        {
            self.name = definition.name
            self.description = definition.description
            self.handler = handler
            self.parameters = try GenerationSchema(
                root: Self.schema(named: definition.name, from: definition.parameters),
                dependencies: [])
        }

        func call(arguments: GeneratedContent) async throws -> String {
            await handler(arguments.jsonString)
        }

        /// Converts the flat JSON Schemas Momo's tools use into a dynamic schema.
        static func schema(named name: String, from json: JSONValue) -> DynamicGenerationSchema {
            let required = Set(json["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let properties = (json["properties"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
            return DynamicGenerationSchema(
                name: "\(name)_arguments",
                properties: properties.map { key, property in
                    DynamicGenerationSchema.Property(
                        name: key, description: property["description"]?.stringValue,
                        schema: propertySchema(named: "\(name)_\(key)", from: property),
                        isOptional: !required.contains(key))
                })
        }

        private static func propertySchema(
            named name: String, from property: JSONValue
        )
            -> DynamicGenerationSchema
        {
            if let choices = property["enum"]?.arrayValue?.compactMap(\.stringValue),
                !choices.isEmpty
            {
                return DynamicGenerationSchema(name: name, anyOf: choices)
            }
            switch property["type"]?.stringValue {
            case "integer": return DynamicGenerationSchema(type: Int.self)
            case "number": return DynamicGenerationSchema(type: Double.self)
            case "boolean": return DynamicGenerationSchema(type: Bool.self)
            default: return DynamicGenerationSchema(type: String.self)
            }
        }
    }

#endif

/// Turns a conversation into a single prompt for models without chat history support,
/// keeping the most recent turns within a character budget.
public enum PromptFlattener {
    public static func prompt(for turns: [ChatTurn], budget: Int) -> String {
        guard let latest = turns.last else { return "" }
        var history: [String] = []
        var used = latest.text.count
        for turn in turns.dropLast().reversed() {
            let speaker = turn.role == .user ? "User" : "Momo"
            let line = "\(speaker): \(turn.text)"
            if used + line.count > budget { break }
            history.insert(line, at: 0)
            used += line.count
        }
        guard !history.isEmpty else { return latest.text }
        return """
            Conversation so far:
            \(history.joined(separator: "\n"))

            User's new message:
            \(latest.text)
            """
    }
}
