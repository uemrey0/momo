import MomoBrain
import SwiftUI

extension BrainOption {
    /// The provider whose model the user can pick, and where the choice is saved.
    var modelSetting: (providerID: String, keyPath: WritableKeyPath<BrainSettings, String>)? {
        switch self {
        case .chatGPT: ("codex", \.codexModel)
        case .gemini: ("gemini-cli", \.geminiCLIModel)
        case .claude: ("anthropic", \.anthropicModel)
        case .openAI: ("openai", \.openAIModel)
        case .geminiAPI: ("gemini-api", \.geminiModel)
        case .openRouter: ("openrouter", \.openRouterModel)
        case .ollama: ("ollama", \.ollamaModel)
        case .lmStudio: ("lmstudio", \.lmStudioModel)
        case .appleIntelligence: nil
        }
    }
}

extension AppModel {
    /// The model `option` uses, when the user picked one.
    func chosenModel(for option: BrainOption) -> String? {
        guard let setting = option.modelSetting else { return nil }
        let value = settings.preferences.brains[keyPath: setting.keyPath]
        return value.isEmpty ? nil : value
    }
}

/// Lets the user pick a model from the provider's own list, with readable names, short
/// descriptions and the provider's recommendation, instead of typing a model name.
struct ModelPicker: View {
    var option: BrainOption
    var model: AppModel
    @State private var choices: [ModelChoice]?
    @State private var failed = false
    @State private var search = ""

    private var setting: (providerID: String, keyPath: WritableKeyPath<BrainSettings, String>)? {
        option.modelSetting
    }

    private var selection: String {
        guard let setting else { return "" }
        return model.settings.preferences.brains[keyPath: setting.keyPath]
    }

    /// The row that shows as chosen. An empty setting follows the provider's recommendation.
    private var effectiveSelection: String {
        if selection.isEmpty, let choices, !choices.contains(where: { $0.id.isEmpty }) {
            return choices.first(where: \.isRecommended)?.id ?? ""
        }
        return selection
    }

    private var visibleChoices: [ModelChoice] {
        var list = choices ?? []
        // Keep a model chosen earlier visible even if the provider no longer lists it.
        if !selection.isEmpty, !list.contains(where: { $0.id == selection }) {
            list.insert(ModelChoice(id: selection, name: selection), at: 0)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private var isLong: Bool { (choices?.count ?? 0) > 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: L("Model")).font(.headline)
            StepNote(
                text: L(
                    "Choose which model Momo thinks with. The recommended one is a great place to start."
                ))
            if choices == nil && !failed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: L("Getting the list of models…")).foregroundStyle(.secondary)
                }
            } else if failed {
                ProblemBanner(text: L("Couldn't get the list of models."))
                Button(L("Try Again")) { Task { await load() } }
            } else {
                if isLong {
                    TextField(L("Search models"), text: $search)
                        .textFieldStyle(.roundedBorder)
                }
                if isLong {
                    ScrollView {
                        rows
                    }
                    .frame(height: 240)
                } else {
                    rows
                }
            }
        }
        .task(id: option) { await load() }
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(visibleChoices) { choice in
                ModelRow(choice: choice, isSelected: choice.id == effectiveSelection) {
                    select(choice.id)
                }
            }
        }
    }

    private func select(_ id: String) {
        guard let setting else { return }
        model.settings.preferences.brains[keyPath: setting.keyPath] = id
        model.enableBrain(setting.providerID)
    }

    private func load() async {
        guard let setting else { return }
        failed = false
        let brains = model.settings.preferences.brains
        do {
            switch option {
            case .ollama:
                guard let base = OllamaSetup.apiBase(from: brains.ollamaURL) else { return }
                choices = try await OllamaSetup.installedModels(base: base).map {
                    ModelChoice(id: $0, name: $0)
                }
            case .lmStudio:
                guard let url = URL(string: brains.lmStudioURL) else { return }
                choices = try await OpenAICompatibleProvider.listModels(baseURL: url).map {
                    ModelChoice(id: $0, name: $0)
                }
            default:
                choices = try await ModelCatalog.choices(
                    for: setting.providerID, key: model.settings.keys.key(for: setting.providerID))
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct ModelRow: View {
    var choice: ModelChoice
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: choice.name).font(.body.weight(.medium))
                        if choice.isRecommended {
                            Text(verbatim: L("Recommended"))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                    if let detail = choice.detail, detail != choice.name {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
