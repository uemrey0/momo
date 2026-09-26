import AppKit
import MomoBrain
import SwiftUI

/// Connects a provider with an API key: open the key page, copy the key, and Momo spots it
/// in the clipboard, checks it with the provider and saves it to the Keychain.
struct APIKeySetupView: View {
    var option: BrainOption
    var model: AppModel
    @State private var key = ""
    @State private var result: KeyCheck?
    @State private var isChecking = false
    @State private var spottedInClipboard = false
    @State private var openedKeyPage = false
    @State private var lastClipboardChange = NSPasteboard.general.changeCount

    private var providerID: String { option.keyProviderID ?? "" }
    private var hasSavedKey: Bool { !(model.settings.keys.key(for: providerID) ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SetupStep(
                number: 1, title: L("Create a key"),
                state: hasSavedKey || openedKeyPage || !key.isEmpty ? .done : .current
            ) {
                StepNote(text: option.keyDirections)
                openPageButton
            }
            SetupStep(
                number: 2, title: L("Copy the key"),
                state: hasSavedKey ? .done : (openedKeyPage || !key.isEmpty ? .current : .upcoming)
            ) {
                StepNote(text: L("Just copy it. Momo notices the key when you come back here."))
                keyField
            }
            if hasSavedKey && result != .valid {
                ConnectedBanner(
                    text: String(format: L("%@ is connected with your key."), option.title))
                Button(L("Use a different key")) {
                    model.settings.keys.setKey("", for: providerID)
                    key = ""
                    result = nil
                    refresh()
                }
            }
            switch result {
            case .valid:
                ConnectedBanner(
                    text: String(format: L("Connected! Momo can use %@ now."), option.title))
            case .rejected:
                ProblemBanner(
                    text: L("That key didn't work. Make sure you copied all of it, then try again.")
                )
            case .unreachable:
                ProblemBanner(
                    text: String(
                        format: L(
                            "Couldn't reach %@ to check the key. Check your internet connection."),
                        option.title))
                Button(L("Save It Anyway")) { save() }
            case nil:
                EmptyView()
            }
            if hasSavedKey || result == .valid {
                openPageButton.buttonStyle(.link)
            }
        }
        .onAppear { checkClipboard(force: true) }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in checkClipboard(force: false) }
        .task {
            // Only the change counter is watched; the clipboard is read when it changes and
            // the user is back in Momo.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                if NSApp.isActive { checkClipboard(force: false) }
            }
        }
    }

    private var openPageButton: some View {
        Button(String(format: L("Open %@"), option.keyPage?.host() ?? option.title)) {
            if let page = option.keyPage { NSWorkspace.shared.open(page) }
            openedKeyPage = true
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var keyField: some View {
        HStack {
            SecureField(L("Paste your key here"), text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            Button(L("Paste")) {
                if let text = NSPasteboard.general.string(forType: .string) {
                    key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    connect()
                }
            }
        }
        if spottedInClipboard {
            Label(L("Found your key in the clipboard."), systemImage: "doc.on.clipboard.fill")
                .font(.callout)
                .foregroundStyle(.green)
        }
        HStack {
            Button(L("Connect")) { connect() }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isChecking)
            if isChecking {
                ProgressView().controlSize(.small)
                Text(verbatim: L("Checking the key…")).foregroundStyle(.secondary)
            }
        }
    }

    /// Picks up a key the user just copied.
    private func checkClipboard(force: Bool) {
        let pasteboard = NSPasteboard.general
        guard !hasSavedKey, force || pasteboard.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
            APIKeySetup.looksLikeKey(text, for: providerID)
        else { return }
        let found = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found != key else { return }
        key = found
        spottedInClipboard = true
        connect()
    }

    private func connect() {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isChecking else { return }
        isChecking = true
        result = nil
        Task {
            let check = await APIKeySetup.validate(candidate, for: providerID)
            isChecking = false
            result = check
            if check == .valid { save() }
        }
    }

    private func save() {
        model.settings.keys.setKey(key, for: providerID)
        if result != .valid { result = .valid }
        refresh()
    }

    private func refresh() {
        model.enableBrain(providerID)
    }
}
