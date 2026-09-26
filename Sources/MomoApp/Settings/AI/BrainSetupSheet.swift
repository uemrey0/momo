import AppKit
import MomoBrain
import SwiftUI

/// Walks the user through connecting one brain, step by step, without Terminal.
struct BrainSetupSheet: View {
    var option: BrainOption
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(option.tint.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: String(format: L("Connect %@"), option.title))
                        .font(.title2.weight(.semibold))
                    Text(verbatim: option.subtitle).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                    if model.isConnected(option), option.modelSetting != nil,
                        option != .ollama, option != .lmStudio
                    {
                        Divider()
                        ModelPicker(option: option, model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                if model.isConnected(option) {
                    Button(String(format: L("Stop using %@"), option.title), role: .destructive) {
                        model.disconnect(option)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
                Spacer()
                Button(L("Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 560)
    }

    @ViewBuilder
    private var content: some View {
        switch option {
        case .appleIntelligence: AppleIntelligenceSetup(model: model)
        case .ollama: OllamaSetupView(model: model)
        case .lmStudio: LMStudioSetupView(model: model)
        case .chatGPT: ChatGPTSetupView(model: model)
        case .gemini: GeminiSetupView(model: model)
        case .claude:
            APIKeySetupView(option: option, model: model)
            ClaudePlanNote(model: model)
        case .openAI, .geminiAPI, .openRouter:
            APIKeySetupView(option: option, model: model)
        }
    }
}

// MARK: - Building blocks

/// Where a setup step stands.
enum StepState {
    case done, current, upcoming
}

/// A numbered step. Only the current step shows its details.
struct SetupStep<Content: View>: View {
    var number: Int
    var title: String
    var state: StepState
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(state == .upcoming ? Color.secondary.opacity(0.2) : badgeColor)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                } else {
                    Text(verbatim: "\(number)").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(state == .upcoming ? Color.secondary : .white)
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: title)
                    .font(.headline)
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
                    .padding(.top, 2)
                if state == .current {
                    content
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var badgeColor: Color {
        state == .done ? .green : .accentColor
    }
}

/// A short explanation under a step.
struct StepNote: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A success message once everything is connected.
struct ConnectedBanner: View {
    var text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        }
        .font(.callout.weight(.medium))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A problem message.
struct ProblemBanner: View {
    var text: String

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

private func step(done: Bool, previousDone: Bool) -> StepState {
    done ? .done : (previousDone ? .current : .upcoming)
}

private func openApp(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Apple Intelligence

private struct AppleIntelligenceSetup: View {
    var model: AppModel

    private var availability: ProviderAvailability? {
        model.statuses(for: .appleIntelligence).first?.availability
    }

    var body: some View {
        if availability?.isReady == true {
            ConnectedBanner(
                text: L("Apple Intelligence is on. Momo uses it for quick, private answers."))
        } else {
            StepNote(
                text: L(
                    "Apple Intelligence runs on your Mac and needs macOS 26 with Apple Intelligence turned on."
                ))
            if case .unavailable(let reason) = availability {
                ProblemBanner(text: reason)
            }
            Button(L("Open Apple Intelligence Settings")) {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
                {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            StepNote(text: L("When you come back, Momo checks again on its own."))
        }
    }
}

// MARK: - Ollama

private struct OllamaSetupView: View {
    var model: AppModel
    @State private var isInstalled = OllamaSetup.isInstalled
    @State private var models: [String]?
    @State private var downloading: String?
    @State private var progress: OllamaSetup.PullProgress?
    @State private var problem: String?
    @State private var download: Task<Void, Never>?

    private var settings: AppSettings { model.settings }
    private var base: URL? { OllamaSetup.apiBase(from: settings.preferences.brains.ollamaURL) }
    private var isRunning: Bool { models != nil }
    private var chosen: String { settings.preferences.brains.ollamaModel }
    private var hasModel: Bool { models?.contains(chosen) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1, title: L("Get the Ollama app"),
                state: step(done: isInstalled || isRunning, previousDone: true)
            ) {
                StepNote(
                    text: L(
                        "Download Ollama and move it to Applications, like any other app. Momo notices when it's there."
                    ))
                Button(L("Download Ollama")) {
                    NSWorkspace.shared.open(URL(literal: "https://ollama.com/download"))
                }
                .buttonStyle(.borderedProminent)
            }
            SetupStep(
                number: 2, title: L("Open Ollama"),
                state: step(done: isRunning, previousDone: isInstalled || isRunning)
            ) {
                StepNote(text: L("Ollama runs quietly in the menu bar and starts with your Mac."))
                Button(L("Open Ollama")) { openApp(OllamaSetup.appURL) }
                    .buttonStyle(.borderedProminent)
            }
            SetupStep(
                number: 3, title: L("Choose a model"),
                state: step(done: hasModel, previousDone: isRunning)
            ) {
                modelChoice
            }
            if hasModel {
                ConnectedBanner(
                    text: String(
                        format: L("Momo thinks with %@ on your Mac. Nothing leaves this Mac."),
                        chosen))
                modelChoice
            }
        }
        .task { await watch() }
    }

    @ViewBuilder
    private var modelChoice: some View {
        if let models, !models.isEmpty {
            Picker(L("Model"), selection: modelBinding) {
                ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
        if let downloading {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(format: L("Downloading %@…"), downloading))
                    .font(.callout.weight(.medium))
                ProgressView(value: progress?.fraction ?? 0)
                HStack {
                    Text(verbatim: progress?.status ?? L("Starting…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Cancel")) { download?.cancel() }.controlSize(.small)
                }
            }
        } else {
            StepNote(
                text: models?.isEmpty == false
                    ? L("Or download another one:")
                    : L("Download one of these. They work well with Momo and speak many languages.")
            )
            ForEach(OllamaSetup.suggestedModels) { suggestion in
                suggestionRow(suggestion)
            }
        }
        if let problem { ProblemBanner(text: problem) }
    }

    private func suggestionRow(_ suggestion: OllamaSetup.SuggestedModel) -> some View {
        let isRecommended = suggestion == OllamaSetup.recommendedModel()
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: tierName(suggestion.tier)).font(.body.weight(.medium))
                    if isRecommended {
                        Text(verbatim: L("Best for this Mac"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                Text(
                    verbatim: String(
                        format: L("%@ · %@ GB download"), suggestion.id,
                        suggestion.gigabytes.formatted(.number.precision(.fractionLength(1))))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if models?.contains(suggestion.id) == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(L("Download")) { pull(suggestion.id) }
                    .buttonStyle(.bordered)
                    .disabled(!isRunning)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func tierName(_ tier: OllamaSetup.SuggestedModel.Tier) -> String {
        switch tier {
        case .fast: L("Quick and light")
        case .balanced: L("Balanced")
        case .smart: L("Smartest")
        }
    }

    private var modelBinding: Binding<String> {
        Binding {
            chosen
        } set: {
            settings.preferences.brains.ollamaModel = $0
            model.enableBrain("ollama")
        }
    }

    private func watch() async {
        while !Task.isCancelled {
            isInstalled = OllamaSetup.isInstalled
            if let base {
                models = try? await OllamaSetup.installedModels(base: base)
            }
            // Pick a model on the user's behalf when there is exactly one obvious choice.
            if chosen.isEmpty, let first = models?.first {
                modelBinding.wrappedValue = first
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func pull(_ name: String) {
        guard let base else { return }
        problem = nil
        downloading = name
        progress = nil
        download = Task {
            do {
                for try await update in OllamaSetup.pull(name, base: base) {
                    progress = update
                }
                if !Task.isCancelled {
                    models = try? await OllamaSetup.installedModels(base: base)
                    modelBinding.wrappedValue = name
                }
            } catch {
                if !Task.isCancelled {
                    problem = String(
                        format: L("The download stopped: %@"), error.localizedDescription)
                }
            }
            downloading = nil
        }
    }
}

// MARK: - LM Studio

private struct LMStudioSetupView: View {
    var model: AppModel
    @State private var isInstalled = LMStudioSetup.appURL != nil
    @State private var models: [String]?

    private var settings: AppSettings { model.settings }
    private var isRunning: Bool { models != nil }
    private var chosen: String { settings.preferences.brains.lmStudioModel }
    private var hasModel: Bool { models?.contains(chosen) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1, title: L("Get the LM Studio app"),
                state: step(done: isInstalled || isRunning, previousDone: true)
            ) {
                StepNote(text: L("Download LM Studio and move it to Applications."))
                Button(L("Download LM Studio")) {
                    NSWorkspace.shared.open(URL(literal: "https://lmstudio.ai/download"))
                }
                .buttonStyle(.borderedProminent)
            }
            SetupStep(
                number: 2, title: L("Start LM Studio's server"),
                state: step(done: isRunning, previousDone: isInstalled || isRunning)
            ) {
                StepNote(
                    text: L(
                        "In LM Studio, open the Developer view and switch the server on. In its settings you can let it start with your Mac."
                    ))
                Button(L("Open LM Studio")) { openApp(LMStudioSetup.appURL) }
                    .buttonStyle(.borderedProminent)
            }
            SetupStep(
                number: 3, title: L("Choose a model"),
                state: step(done: hasModel, previousDone: isRunning)
            ) {
                picker
            }
            if hasModel {
                ConnectedBanner(
                    text: String(
                        format: L("Momo thinks with %@ on your Mac. Nothing leaves this Mac."),
                        chosen))
                picker
            }
        }
        .task { await watch() }
    }

    @ViewBuilder
    private var picker: some View {
        if let models, !models.isEmpty {
            Picker(L("Model"), selection: modelBinding) {
                ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .pickerStyle(.radioGroup)
        } else {
            StepNote(
                text: L(
                    "Download a model in LM Studio's Discover view. It shows up here right away."))
        }
    }

    private var modelBinding: Binding<String> {
        Binding {
            chosen
        } set: {
            settings.preferences.brains.lmStudioModel = $0
            model.enableBrain("lmstudio")
        }
    }

    private func watch() async {
        while !Task.isCancelled {
            isInstalled = LMStudioSetup.appURL != nil
            if let url = URL(string: settings.preferences.brains.lmStudioURL) {
                models = try? await OpenAICompatibleProvider.listModels(baseURL: url)
            }
            if chosen.isEmpty, let first = models?.first { modelBinding.wrappedValue = first }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

// MARK: - ChatGPT

private struct ChatGPTSetupView: View {
    var model: AppModel
    @State private var hasCodex = CodexSetup.locate() != nil
    @State private var isSignedIn = false
    @State private var signIn: Task<Void, Never>?
    @State private var signInPage: URL?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1, title: L("Get Codex"),
                state: step(done: hasCodex, previousDone: true)
            ) {
                StepNote(
                    text: L(
                        "Codex is OpenAI's official tool for using your ChatGPT plan. Momo downloads it into its own folder. If you have the ChatGPT app or Codex already, Momo finds it on its own."
                    ))
                ToolDownloadButton(tool: .codex, megabytes: 95) { hasCodex = true }
            }
            SetupStep(
                number: 2, title: L("Sign in with your ChatGPT account"),
                state: step(done: isSignedIn, previousDone: hasCodex)
            ) {
                StepNote(
                    text: L("Your browser opens so you can sign in. Momo never sees your password.")
                )
                if signIn != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: L("Finish signing in in your browser…"))
                        Spacer()
                        if let signInPage {
                            Button(L("Open Again")) { NSWorkspace.shared.open(signInPage) }
                                .controlSize(.small)
                        }
                        Button(L("Cancel")) { stopSignIn() }.controlSize(.small)
                    }
                } else {
                    Button(L("Sign in with ChatGPT")) { startSignIn() }
                        .buttonStyle(.borderedProminent)
                }
                if let problem { ProblemBanner(text: problem) }
            }
            if isSignedIn {
                ConnectedBanner(
                    text: L(
                        "ChatGPT is connected. Momo uses your plan for bigger questions and asks before sending anything."
                    ))
            }
        }
        .task { await watch() }
        .onDisappear { stopSignIn() }
    }

    private func watch() async {
        while !Task.isCancelled {
            hasCodex = CodexSetup.locate() != nil
            let signedIn = hasCodex ? await CodexSetup.isSignedIn() : false
            if signedIn && !isSignedIn {
                model.enableBrain("codex")
                stopSignIn()
            }
            isSignedIn = signedIn
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func startSignIn() {
        problem = nil
        signInPage = nil
        signIn = Task {
            do {
                for try await line in CodexSetup.signIn() {
                    if signInPage == nil { signInPage = firstWebAddress(in: line) }
                }
            } catch {
                if !Task.isCancelled {
                    problem = L("Signing in didn't finish. Try again.")
                }
            }
            signIn = nil
            isSignedIn = await CodexSetup.isSignedIn()
            if isSignedIn { model.enableBrain("codex") }
        }
    }

    private func stopSignIn() {
        signIn?.cancel()
        signIn = nil
    }
}

// MARK: - Gemini

/// Gemini with the user's Google account: Momo gets the official Gemini CLI and starts its
/// Google sign-in. No API key, so no extra charges.
private struct GeminiSetupView: View {
    var model: AppModel
    @State private var hasCLI = GeminiCLISetup.isInstalled
    @State private var isSignedIn = GeminiCLIProvider.isSignedIn
    @State private var signIn: Task<Void, Never>?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1, title: L("Get Gemini CLI"), state: step(done: hasCLI, previousDone: true)
            ) {
                StepNote(
                    text: L(
                        "Gemini CLI is Google's official tool for using Gemini with your Google account. Momo downloads it into its own folder."
                    ))
                ToolDownloadButton(tool: .gemini, megabytes: 37) { hasCLI = true }
            }
            SetupStep(
                number: 2, title: L("Sign in with Google"),
                state: step(done: isSignedIn, previousDone: hasCLI)
            ) {
                StepNote(
                    text: L(
                        "Your browser opens so you can sign in. Momo never sees your password."))
                if signIn != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: L("Finish signing in in your browser…"))
                        Spacer()
                        Button(L("Cancel")) { stopSignIn() }.controlSize(.small)
                    }
                } else {
                    Button(L("Sign in with Google")) { start() }
                        .buttonStyle(.borderedProminent)
                }
                if let problem { ProblemBanner(text: problem) }
            }
            if isSignedIn {
                ConnectedBanner(
                    text: L(
                        "Gemini is connected with your Google account. With Google AI Pro or Ultra you get higher limits. There are no extra charges."
                    ))
            }
        }
        .task {
            while !Task.isCancelled {
                hasCLI = GeminiCLISetup.isInstalled
                let signedIn = GeminiCLIProvider.isSignedIn
                if signedIn && !isSignedIn { model.enableBrain("gemini-cli") }
                isSignedIn = signedIn
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { stopSignIn() }
    }

    private func start() {
        problem = nil
        signIn = Task {
            do {
                for try await _ in GeminiCLISetup.signIn() {}
            } catch {
                if !Task.isCancelled { problem = L("Signing in didn't finish. Try again.") }
            }
            signIn = nil
            isSignedIn = GeminiCLIProvider.isSignedIn
            if isSignedIn { model.enableBrain("gemini-cli") }
        }
    }

    private func stopSignIn() {
        signIn?.cancel()
        signIn = nil
    }
}

/// Downloads one of the official command line tools, with progress.
private struct ToolDownloadButton: View {
    var tool: ManagedTool
    var megabytes: Int
    var installed: () -> Void
    @State private var progress: Double?
    @State private var download: Task<Void, Never>?
    @State private var problem: String?

    var body: some View {
        if let progress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                HStack {
                    Text(
                        verbatim: progress < 1
                            ? String(format: L("Downloading… %lld%%"), Int(progress * 100))
                            : L("Checking and setting up…")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Cancel")) { download?.cancel() }.controlSize(.small)
                }
            }
        } else {
            Button(String(format: L("Download for Me (%lld MB)"), megabytes)) { start() }
                .buttonStyle(.borderedProminent)
        }
        if let problem { ProblemBanner(text: problem) }
    }

    private func start() {
        problem = nil
        progress = 0
        download = Task {
            do {
                try await ToolInstaller.install(tool) { value in
                    Task { @MainActor in
                        if progress != nil { progress = value }
                    }
                }
                installed()
            } catch {
                if !Task.isCancelled {
                    problem = String(
                        format: L("The download didn't work: %@"), error.localizedDescription)
                }
            }
            progress = nil
        }
    }
}

// MARK: - Claude

private struct ClaudePlanNote: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L("Have a Claude Pro or Max plan?")).font(.headline)
            StepNote(
                text: L(
                    "Anthropic doesn't let other apps use Claude plans, but Claude can use Momo: connect them and Claude can read and update your tasks, notes and memories."
                ))
            Button(L("Connect Momo to Claude")) {
                model.settingsNavigation.pane = .connections
                dismiss()
            }
        }
    }
}
