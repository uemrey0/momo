import MomoKit
import SwiftUI

/// Momo's colours and shapes. The panel is always dark so it reads as part of the notch.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.86, blue: 0.75)
    static let subscription = Color(red: 0.78, green: 0.75, blue: 1.0)
    static let apiKey = Color(red: 1.0, green: 0.83, blue: 0.62)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.42)
    static let panelBackground = Color(red: 0.07, green: 0.075, blue: 0.095)
    static let card = Color.white.opacity(0.06)
    static let cardStrong = Color.white.opacity(0.1)
    static let secondaryText = Color.white.opacity(0.6)
    static let tertiaryText = Color.white.opacity(0.4)
    static let cornerRadius: CGFloat = 22

    static func color(for kind: BrainKind?) -> Color {
        switch kind {
        case .subscription: subscription
        case .apiKey: apiKey
        default: accent
        }
    }
}

/// A small capsule label.
struct Pill: View {
    var text: String
    var color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(verbatim: text).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A borderless button with a subtle hover highlight.
struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    isHovering ? Theme.cardStrong : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
    }
}

/// A vertical scroll view that renders as a plain stack in snapshot mode, where image
/// rendering cannot draw scroll views.
struct PanelScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

extension EnvironmentValues {
    /// Replaces effects that image rendering cannot capture (such as the frosted background).
    @Entry var snapshotMode = false
}
