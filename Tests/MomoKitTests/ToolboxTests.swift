import Foundation
import Testing

@testable import MomoKit

@Suite("Toolbox")
struct ToolboxTests {
    let echo = ClosureTool(ToolDefinition(name: "echo", description: "Echo")) { arguments in
        arguments["text"]?.stringValue ?? ""
    }
    let dangerous = ClosureTool(
        ToolDefinition(name: "wipe", description: "Wipe", requiresConfirmation: true)
    ) { _ in "wiped" }

    @Test("runs tools by name")
    func runsTools() async {
        let box = Toolbox([echo])
        let result = await box.execute(
            ToolCall(id: "1", name: "echo", arguments: #"{"text":"hi"}"#))
        #expect(result.output == "hi")
        #expect(!result.isError)
    }

    @Test("keeps the label a tool describes itself with")
    func keepsActivityLabels() {
        let labelled = ClosureTool(
            ToolDefinition(
                name: "weather", description: "Weather", activityLabel: "Looking outside")
        ) { _ in "sunny" }
        let box = Toolbox([echo, labelled])
        #expect(box.definitions.map(\.activityLabel) == [nil, "Looking outside"])
    }

    @Test("reports unknown tools and bad JSON as errors")
    func reportsErrors() async {
        let box = Toolbox([echo])
        #expect(await box.execute(ToolCall(id: "1", name: "nope", arguments: "{}")).isError)
        #expect(await box.execute(ToolCall(id: "2", name: "echo", arguments: "{oops")).isError)
    }

    @Test("asks before running tools that need confirmation")
    func asksForConfirmation() async {
        let box = Toolbox([dangerous])
        let declined = await box.execute(
            ToolCall(id: "1", name: "wipe", arguments: "{}"), confirm: { _ in false })
        #expect(declined.isError)
        let approved = await box.execute(
            ToolCall(id: "2", name: "wipe", arguments: "{}"), confirm: { _ in true })
        #expect(approved.output == "wiped")
        let unanswered = await box.execute(ToolCall(id: "3", name: "wipe", arguments: "{}"))
        #expect(unanswered.isError)
    }
}
