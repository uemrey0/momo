import AppKit
import MomoBrain
import MomoFace
import SwiftUI

/// Shows the welcome tour in its own window.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: AppModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        super.init()
        window.contentView = NSHostingView(rootView: OnboardingView(model: model))
        window.delegate = self
    }

    func show() {
        ForegroundPresence.enter(window)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        ForegroundPresence.leave(window)
    }

    func close() {
        window.close()
    }
}

/// A short, friendly tour: hello, pick a brain, how to use Momo.
struct OnboardingView: View {
    var model: AppModel
    @State private var step = 0
    @State private var engine = FaceEngine()

    var body: some View {
        VStack(spacing: 0) {
            FaceView(engine: engine, layout: FaceLayout(topInset: 0, capWidth: 0, scale: 1.1))
                .frame(height: 170)
                .clipped()
            Group {
                switch step {
                case 0: welcome
                case 1: brains
                default: tips
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            footer
        }
        .frame(width: 560, height: 520)
        .background(Theme.panelBackground)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .onAppear { engine.flashMood(.happy, for: 2) }
        .task { await model.assistant.refreshProviders() }
    }

    private var welcome: some View {
        VStack(spacing: 12) {
            Text(verbatim: L("Hi, I'm Momo!"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(
                verbatim: L(
                    "I live in your notch. I keep your tasks, notes and habits, remember what matters to you, and answer questions, privately on your Mac whenever I can."
                )
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private var brains: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: L("Pick my brains"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(
                verbatim: L(
                    "I think on your Mac first. For bigger jobs I can borrow the ChatGPT or Gemini plan you already have, or an API key. I always ask before anything leaves your Mac."
                )
            )
            .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.assistant.providerStatuses) { status in
                    HStack {
                        Image(
                            systemName: status.availability.isReady
                                ? "checkmark.circle.fill" : "circle.dashed"
                        )
                        .foregroundStyle(
                            status.availability.isReady ? Theme.accent : Theme.tertiaryText)
                        Text(verbatim: status.info.name)
                        Spacer()
                        if case .unavailable(let reason) = status.availability {
                            Text(verbatim: reason)
                                .font(.caption)
                                .foregroundStyle(Theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 240, alignment: .trailing)
                        }
                    }
                    .font(.system(size: 13))
                }
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            Button(L("Set up brains in Settings")) { model.openSettings(.ai) }
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L("How to reach me"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
            tip("keyboard", L("Press ⌥Space anywhere to talk to me."))
            tip("cursorarrow.click", L("Click me in the notch to open my panel."))
            tip(
                "checklist",
                L(
                    "Say things like “remind me to call Ayşe at 3” or “note that the Wi-Fi password is on the fridge”."
                ))
            tip("moon.zzz", L("I doze off when you step away. Wiggle the mouse and I'll wake up."))
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(index == step ? Theme.accent : Theme.tertiaryText)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step > 0 {
                Button(L("Back")) { withAnimation { step -= 1 } }
            }
            Button(step < 2 ? L("Continue") : L("Start")) {
                if step < 2 {
                    withAnimation(.spring(duration: 0.35)) { step += 1 }
                    engine.perform(step == 1 ? .lookAround : .wink)
                } else {
                    model.finishOnboarding()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }
}
