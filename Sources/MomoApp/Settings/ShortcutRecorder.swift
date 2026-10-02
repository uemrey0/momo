import AppKit
import SwiftUI

/// A settings row for a global shortcut: click the shortcut and press a new combination to
/// change it. Esc cancels, Delete clears it.
struct ShortcutRecorderRow: View {
    var action: ShortcutAction
    var center: ShortcutCenter

    private var shortcut: HotKeyShortcut? { center.shortcut(for: action) }
    private var isRecording: Bool { center.recordingAction == action }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(action.title) {
                HStack(spacing: 6) {
                    recorder
                    if shortcut != nil && !isRecording {
                        Button {
                            center.set(nil, for: action)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L("Clear shortcut"))
                        .accessibilityLabel(L("Clear shortcut"))
                    }
                    if shortcut != action.defaultShortcut && !isRecording {
                        Button {
                            center.set(action.defaultShortcut, for: action)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Reset to default"))
                        .accessibilityLabel(L("Reset to default"))
                    }
                }
            }
            if let note {
                Text(verbatim: note.text)
                    .font(.caption)
                    .foregroundStyle(
                        note.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
        .onAppear { center.apply() }
        .onDisappear { if isRecording { center.stopRecording() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
            _ in
            if isRecording { center.stopRecording() }
        }
    }

    private var recorder: some View {
        Button {
            if isRecording {
                center.stopRecording()
            } else {
                center.startRecording(action)
            }
        } label: {
            Text(verbatim: label)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isRecording || shortcut == nil ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .accessibilityLabel(String(format: L("%@ shortcut"), action.title))
        .accessibilityValue(shortcut?.displayString ?? L("No shortcut"))
    }

    private var label: String {
        if isRecording { return L("Type shortcut…") }
        return shortcut?.displayString ?? L("Record Shortcut")
    }

    /// A rejected combination, a hint while recording, or a shortcut another app has.
    private var note: (text: String, isWarning: Bool)? {
        if let problem = center.rejections[action] { return (problem.message, true) }
        if isRecording {
            return (L("Press the new shortcut. Esc cancels, Delete clears it."), false)
        }
        if shortcut != nil, center.failedActions.contains(action) {
            return (
                L(
                    "Another app is using this shortcut, so it doesn't work. Choose a different one."
                ), true
            )
        }
        return nil
    }
}
