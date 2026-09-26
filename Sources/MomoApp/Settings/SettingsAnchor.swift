import SwiftUI

extension View {
    /// Marks a setting so search results and other parts of the app can scroll to it and
    /// briefly highlight it. `id` must be unique across Settings.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchorModifier(id: id))
    }
}

private struct SettingsAnchorModifier: ViewModifier {
    var id: String
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    func body(content: Content) -> some View {
        let isHighlighted = navigation?.highlight == id
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.2 : 0))
                    .padding(-5)
                    .allowsHitTesting(false)
            )
            .animation(.easeInOut(duration: 0.35), value: isHighlighted)
    }
}
