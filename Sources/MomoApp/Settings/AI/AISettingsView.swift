import MomoBrain
import SwiftUI

/// The AI page: what Momo thinks with, and one-click ways to connect more.
struct AISettingsView: View {
    var model: AppModel
    @Bindable var navigation: SettingsNavigation
    @State private var showsAdvanced = false

    init(model: AppModel) {
        self.model = model
        self.navigation = model.settingsNavigation
    }

    private var connected: [BrainOption] {
        BrainOption.allCases.filter { model.isConnected($0) }
    }

    var body: some View {
        Form {
            Section {
                StatusHeader(connected: connected, isChecking: model.hasReadyBrain == nil)
            }
            ForEach(BrainOption.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(group.options) { option in
                        BrainOptionRow(
                            option: option, isConnected: model.isConnected(option),
                            open: { navigation.setupOption = option })
                    }
                } header: {
                    Text(verbatim: group.title)
                } footer: {
                    Text(verbatim: group.footer)
                }
            }
            Section {
                DisclosureGroup(isExpanded: $showsAdvanced) {
                    AdvancedBrainSettings(model: model)
                } label: {
                    Text(verbatim: L("Advanced: order, models and routing"))
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $navigation.setupOption) { option in
            BrainSetupSheet(option: option, model: model)
        }
        .task { await model.assistant.refreshProviders() }
        .onChange(of: model.settings.preferences.brains) {
            Task { await model.assistant.refreshProviders() }
        }
    }
}

/// What Momo can think with right now.
private struct StatusHeader: View {
    var connected: [BrainOption]
    var isChecking: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(connected.isEmpty ? Color.orange.gradient : Color.green.gradient)
                Image(systemName: connected.isEmpty ? "sparkles" : "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                if isChecking {
                    Text(verbatim: L("Checking what's available…")).font(.headline)
                } else if connected.isEmpty {
                    Text(verbatim: L("Momo needs a brain to think with")).font(.headline)
                    Text(
                        verbatim: L(
                            "Pick any option below. Each one takes about a minute and never needs Terminal."
                        )
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: L("Momo is ready to think")).font(.headline)
                    Text(
                        verbatim: String(
                            format: L("Connected: %@"),
                            connected.map(\.title).formatted(.list(type: .and)))
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

/// One way to think, with its status and a button to set it up.
private struct BrainOptionRow: View {
    var option: BrainOption
    var isConnected: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: option.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(option.tint.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: option.title).font(.body.weight(.medium))
                Text(verbatim: option.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnected {
                Label(L("Connected"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Button(L("Manage")) { open() }
            } else {
                Button(L("Connect")) { open() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
