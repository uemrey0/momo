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

// MARK: - Panel design

extension Theme {
    /// The springs the panel uses, so everything moves with the same feel.
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let quickSpring = Animation.spring(response: 0.26, dampingFraction: 0.78)

    /// The user's message bubbles.
    static let userBubble = LinearGradient(
        colors: [
            Color(red: 0.42, green: 0.9, blue: 0.78), Color(red: 0.36, green: 0.8, blue: 0.9),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Soft colours for notes and cards, picked by a stable seed so an item keeps its colour.
    static let pastels: [Color] = [
        Color(red: 0.99, green: 0.78, blue: 0.45), Color(red: 0.55, green: 0.85, blue: 0.75),
        Color(red: 0.62, green: 0.72, blue: 1.0), Color(red: 1.0, green: 0.62, blue: 0.7),
        Color(red: 0.8, green: 0.66, blue: 1.0), Color(red: 0.55, green: 0.82, blue: 0.98),
    ]

    static func pastel(for seed: String) -> Color {
        let value = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return pastels[value % pastels.count]
    }
}

/// A tiny, blinking Momo shown next to its messages.
struct MomoAvatar: View {
    var size: CGFloat = 22
    var isAnimated = true

    var body: some View {
        if isAnimated {
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                face(blink: Self.isBlinking(at: timeline.date))
            }
        } else {
            face(blink: false)
        }
    }

    private func face(blink: Bool) -> some View {
        ZStack {
            UnevenRoundedRectangle(
                bottomLeadingRadius: size * 0.42, bottomTrailingRadius: size * 0.42,
                style: .continuous
            )
            .fill(Color(red: 0.12, green: 0.125, blue: 0.15))
            .overlay(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: size * 0.42, bottomTrailingRadius: size * 0.42,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            HStack(spacing: size * 0.22) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: size * 0.13, height: blink ? size * 0.04 : size * 0.22)
                }
            }
            .offset(y: -size * 0.02)
        }
        .frame(width: size * 1.1, height: size)
        .accessibilityHidden(true)
    }

    /// Blinks briefly every few seconds.
    private static func isBlinking(at date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.2) < 0.14
    }
}

/// How tall a panel section would like to be, so the panel can grow and shrink with it.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Writes the view's height into `height` whenever it changes.
    func measureHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            height.wrappedValue = $0
        }
    }
}

/// A friendly greeting for the time of day.
func greeting(for date: Date = Date()) -> String {
    switch Calendar.current.component(.hour, from: date) {
    case 5..<12: L("Good morning!")
    case 12..<18: L("Good afternoon!")
    case 18..<23: L("Good evening!")
    default: L("Up late?")
    }
}

/// The panel's rounded outline, showing only its top `visibleHeight` points. Animating the
/// visible height reveals a growing panel from the top without changing its layout.
struct PanelShape: Shape {
    var visibleHeight: CGFloat

    var animatableData: CGFloat {
        get { visibleHeight }
        set { visibleHeight = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var visible = rect
        visible.size.height = min(rect.height, max(Theme.cornerRadius * 2, visibleHeight))
        return RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .path(in: visible)
    }
}
