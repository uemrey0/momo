import MomoBrain
import MomoKit
import SwiftUI

/// Human-friendly names and help for each brain.
enum BrainDescriptor {
    static func name(_ id: String) -> String {
        switch id {
        case AppleIntelligence.providerID: "Apple Intelligence"
        case "ollama": "Ollama"
        case "lmstudio": "LM Studio"
        case "codex": L("ChatGPT (your plan, via Codex)")
        case "gemini-cli": L("Gemini (your Google account, via Gemini CLI)")
        case "anthropic": L("Claude (API key)")
        case "openai": L("OpenAI (API key)")
        case "gemini-api": L("Google Gemini (API key)")
        case "openrouter": L("OpenRouter (API key)")
        default: id
        }
    }

    static func kind(_ id: String) -> BrainKind {
        switch id {
        case AppleIntelligence.providerID, "ollama", "lmstudio": .local
        case "codex", "gemini-cli": .subscription
        default: .apiKey
        }
    }

    static func kindName(_ kind: BrainKind) -> String {
        switch kind {
        case .local: L("On this Mac")
        case .subscription: L("Your subscription")
        case .apiKey: L("API key")
        }
    }
}

/// Lists every brain with its status and settings.
struct BrainSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(settings.preferences.brains.order.enumerated()), id: \.element) {
                    index, id in
                    BrainRow(
                        id: id, index: index, settings: settings,
                        status: model.assistant.providerStatuses.first { $0.id == id },
                        move: { move(id, by: $0) })
                }
            } header: {
                Text(verbatim: L("Brains"))
            } footer: {
                Text(
                    verbatim: L(
                        "Momo uses the first ready brain on your Mac for everyday requests and asks before sending bigger jobs to a remote brain. Use the arrows to set the order."
                    ))
            }
            Section {
                Toggle(
                    L("Ask before using a remote brain"),
                    isOn: $settings.preferences.brains.askBeforeRemote)
                LabeledContent(L("Use a remote brain for")) {
                    Picker(
                        selection: $settings.preferences.brains.difficultyThreshold
                    ) {
                        Text(verbatim: L("Most requests")).tag(2)
                        Text(verbatim: L("Harder requests")).tag(3)
                        Text(verbatim: L("Only the hardest requests")).tag(4)
                        Text(verbatim: L("Only very long requests")).tag(6)
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            } header: {
                Text(verbatim: L("Routing"))
            }
        }
        .formStyle(.grouped)
        .task { await model.assistant.refreshProviders() }
        .onChange(of: settings.preferences.brains) {
            Task { await model.assistant.refreshProviders() }
        }
    }

    private func move(_ id: String, by offset: Int) {
        var order = settings.preferences.brains.order
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        settings.preferences.brains.order = order
    }
}

private struct BrainRow: View {
    var id: String
    var index: Int
    @Bindable var settings: AppSettings
    var status: ProviderStatus?
    var move: (Int) -> Void
    @State private var isExpanded = false

    private var isEnabled: Binding<Bool> {
        Binding {
            !settings.preferences.brains.disabled.contains(id)
        } set: { enabled in
            if enabled {
                settings.preferences.brains.disabled.remove(id)
            } else {
                settings.preferences.brains.disabled.insert(id)
            }
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            BrainConfiguration(id: id, settings: settings)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .help(statusText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: BrainDescriptor.name(id))
                    Text(verbatim: statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(verbatim: BrainDescriptor.kindName(BrainDescriptor.kind(id)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Move up"))
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Move down"))
                Toggle(isOn: isEnabled) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }

    private var statusText: String {
        if settings.preferences.brains.disabled.contains(id) { return L("Turned off") }
        switch status?.availability {
        case .ready: return L("Ready")
        case .unavailable(let reason): return reason
        case nil: return L("Not set up yet")
        }
    }

    private var statusColor: Color {
        if settings.preferences.brains.disabled.contains(id) { return .gray }
        switch status?.availability {
        case .ready: return .green
        case .unavailable: return .orange
        case nil: return .gray.opacity(0.5)
        }
    }
}

/// The settings for one brain.
private struct BrainConfiguration: View {
    var id: String
    @Bindable var settings: AppSettings
    @State private var key = ""
    @State private var savedKey = false
    @State private var serverModels: [String] = []
    @State private var isLoadingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch id {
            case AppleIntelligence.providerID:
                Text(
                    verbatim: L(
                        "Runs privately on your Mac. Needs macOS 26 with Apple Intelligence turned on."
                    )
                )
                .foregroundStyle(.secondary)
            case "ollama":
                localServer(
                    url: $settings.preferences.brains.ollamaURL,
                    model: $settings.preferences.brains.ollamaModel,
                    help: L("Install Ollama from ollama.com, then download a model, for example:"),
                    command: "ollama pull qwen3:8b")
            case "lmstudio":
                localServer(
                    url: $settings.preferences.brains.lmStudioURL,
                    model: $settings.preferences.brains.lmStudioModel,
                    help: L(
                        "Install LM Studio from lmstudio.ai, download a model and start its local server."
                    ),
                    command: nil)
            case "codex":
                cliHelp(
                    text: L(
                        "Uses your ChatGPT plan. Install the official Codex CLI and sign in once:"),
                    commands: ["npm install -g @openai/codex", "codex login"])
                TextField(L("Model (optional)"), text: $settings.preferences.brains.codexModel)
            case "gemini-cli":
                cliHelp(
                    text: L(
                        "Uses your Google account. Install the official Gemini CLI and sign in once:"
                    ),
                    commands: ["npm install -g @google/gemini-cli", "gemini"])
                TextField(L("Model (optional)"), text: $settings.preferences.brains.geminiCLIModel)
            case "anthropic":
                keyField(link: "https://console.anthropic.com/settings/keys")
                Picker(L("Model"), selection: $settings.preferences.brains.anthropicModel) {
                    ForEach(AnthropicProvider.suggestedModels, id: \.self) { model in
                        Text(verbatim: model).tag(model)
                    }
                }
                Text(
                    verbatim: L(
                        "Claude subscriptions can't be used by other apps. To use your Claude plan with Momo, add Momo to Claude as an MCP server instead (see Privacy)."
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case "openai":
                keyField(link: "https://platform.openai.com/api-keys")
                TextField(L("Model"), text: $settings.preferences.brains.openAIModel)
            case "gemini-api":
                keyField(link: "https://aistudio.google.com/apikey")
                TextField(L("Model"), text: $settings.preferences.brains.geminiModel)
            case "openrouter":
                keyField(link: "https://openrouter.ai/keys")
                TextField(L("Model"), text: $settings.preferences.brains.openRouterModel)
            default:
                EmptyView()
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    @ViewBuilder
    private func localServer(
        url: Binding<String>, model: Binding<String>, help: String, command: String?
    ) -> some View {
        Text(verbatim: help).foregroundStyle(.secondary)
        if let command { CommandSnippet(command: command) }
        TextField(L("Server address"), text: url)
        HStack {
            Picker(L("Model"), selection: model) {
                Text(verbatim: L("Choose a model")).tag("")
                ForEach(
                    serverModels
                        + (serverModels.contains(model.wrappedValue) || model.wrappedValue.isEmpty
                            ? [] : [model.wrappedValue]),
                    id: \.self
                ) { name in
                    Text(verbatim: name).tag(name)
                }
            }
            Button(isLoadingModels ? L("Loading…") : L("Refresh")) {
                Task { await loadModels(url.wrappedValue) }
            }
            .disabled(isLoadingModels)
        }
        .task { await loadModels(url.wrappedValue) }
    }

    private func loadModels(_ address: String) async {
        guard let url = URL(string: address) else { return }
        isLoadingModels = true
        serverModels = (try? await OpenAICompatibleProvider.listModels(baseURL: url)) ?? []
        isLoadingModels = false
    }

    @ViewBuilder
    private func cliHelp(text: String, commands: [String]) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary)
        ForEach(commands, id: \.self) { CommandSnippet(command: $0) }
    }

    @ViewBuilder
    private func keyField(link: String) -> some View {
        HStack {
            SecureField(L("API key"), text: $key)
                .onAppear { key = settings.keys.key(for: id) ?? "" }
            Button(savedKey ? L("Saved") : L("Save")) {
                settings.keys.setKey(key, for: id)
                savedKey = true
                // Rebuild the provider list so the new key is picked up.
                settings.preferences.brains.order = settings.preferences.brains.order
            }
            .disabled(key == (settings.keys.key(for: id) ?? ""))
        }
        .onChange(of: key) { savedKey = false }
        if let url = URL(string: link) {
            Link(L("Get an API key"), destination: url).font(.caption)
        }
        Text(verbatim: L("Keys are stored in your macOS Keychain and only sent to that provider."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A copyable Terminal command.
struct CommandSnippet: View {
    var command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(verbatim: command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button(copied ? L("Copied") : L("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}
