import MomoBrain
import ServiceManagement
import SwiftUI

/// The Settings window.
struct SettingsView: View {
    var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            BrainSettingsView(model: model)
                .tabItem { Label(L("Brains"), systemImage: "brain") }
            VoiceSettingsView(model: model)
                .tabItem { Label(L("Voice"), systemImage: "waveform") }
            ConnectionsSettingsView(model: model)
                .tabItem {
                    Label(L("Connections"), systemImage: "point.3.connected.trianglepath.dotted")
                }
            PrivacySettingsView(model: model)
                .tabItem { Label(L("Privacy"), systemImage: "hand.raised") }
            AboutView()
                .tabItem { Label(L("About"), systemImage: "info.circle") }
        }
        .frame(width: 620, height: 560)
        .onAppear { NSApp.activate() }
    }
}

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings
    var model: AppModel
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Personality"), selection: $settings.preferences.personality) {
                    ForEach(Personality.allCases) { personality in
                        Text(verbatim: personality.displayName).tag(personality)
                    }
                }
            }
            Section {
                LabeledContent(L("Open Momo")) {
                    Text(verbatim: "⌥ Space").font(.system(.body, design: .monospaced))
                }
                Toggle(L("Open at login"), isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchesAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section {
                LabeledContent(L("Doze off after")) {
                    HStack {
                        Slider(value: $settings.preferences.sleepDelayMinutes, in: 1...15, step: 1)
                            .frame(width: 180)
                        Text(
                            verbatim: String(
                                format: L("%lld min"), Int(settings.preferences.sleepDelayMinutes))
                        )
                        .monospacedDigit()
                        .frame(width: 60, alignment: .leading)
                    }
                }
                .onChange(of: settings.preferences.sleepDelayMinutes) { model.applyPreferences() }
            } footer: {
                Text(
                    verbatim: L(
                        "Momo falls asleep when you step away and wakes up when you're back."))
            }
            ReactionsSection(settings: settings, calendar: model.calendar)
            Section {
                Button(L("Show the welcome tour again")) { model.showOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "face.smiling.inverse")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text(verbatim: "Momo").font(.system(size: 28, weight: .bold, design: .rounded))
            Text(verbatim: String(format: L("Version %@"), version)).foregroundStyle(.secondary)
            Text(verbatim: L("A tiny, living companion for your Mac. Free and open source."))
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(L("Website"), destination: URL(literal: "https://github.com/uemrey0/momo"))
                Link(
                    L("Report a problem"),
                    destination: URL(literal: "https://github.com/uemrey0/momo/issues/new/choose"))
            }
            Spacer()
            Text(verbatim: L("Licensed under the Apache License 2.0."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

extension URL {
    /// Creates a URL from a literal that is known to be valid.
    init(literal: StaticString) {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("Invalid URL literal: \(literal)")
        }
        self = url
    }
}
