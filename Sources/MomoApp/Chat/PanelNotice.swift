import SwiftUI

/// A short note in the panel, dismissed with a tap.
struct PanelNotice: View {
    var text: String
    var systemImage: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Theme.apiKey)
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiaryText)
            .help(L("Dismiss"))
            .accessibilityLabel(L("Dismiss"))
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// What to tell the user when Momo couldn't save a change.
func saveFailureMessage(_ error: any Error) -> String {
    String(format: L("Couldn't save: %@"), error.localizedDescription)
}
