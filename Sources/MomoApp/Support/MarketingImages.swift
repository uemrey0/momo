#if DEBUG
    import MomoFace
    import SwiftUI

    /// Renders the README's marketing images from the real character renderer, so they always
    /// match how Momo looks. Part of `make snapshots`.
    @MainActor
    enum MarketingImages {
        /// The static banners. The animated hero comes from `renderHeroFrames(to:)`.
        static func render(to folder: URL) {
            Snapshots.save(AliveBanner(), "alive", folder, jpeg: true)
            Snapshots.save(BrainsBanner(), "brains", folder, jpeg: true)
        }

        /// A frame of the character in a mood, optionally with its particles.
        static func face(
            _ mood: Mood, brain: BrainSource = .local, particles: Bool = false,
            pointer: SIMD2<Double>? = SIMD2(0, 220)
        ) -> FaceState {
            let engine = FaceEngine(random: FixedRandom())
            engine.brain = brain
            engine.setMood(mood)
            guard particles else { return Snapshots.settle(engine, pointer: pointer) }
            engine.isLifeEnabled = false
            var state = FaceState.resting
            for _ in 0..<150 { state = engine.advance(by: 1 / 60, input: .init(pointer: pointer)) }
            for _ in 0..<300 where state.eyeOpenness < 0.99 {
                state = engine.advance(by: 1 / 60, input: .init(pointer: pointer))
            }
            return state
        }

        /// Momo drawn at a size, hanging from the top of its frame.
        struct Character: View {
            var state: FaceState
            var appearance: CharacterAppearance = .classic
            var scale: Double
            var notchWidth: Double = 0
            var notchHeight: Double = 0

            var body: some View {
                let layout = FaceLayout(topInset: notchHeight, capWidth: notchWidth, scale: scale)
                Canvas { context, _ in
                    FaceRenderer.draw(state, in: &context, layout: layout, appearance: appearance)
                }
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
            }
        }

        static let ink = Color(red: 0.09, green: 0.09, blue: 0.12)
        static let mint = Color(red: 0.30, green: 0.84, blue: 0.72)
        static let violet = Color(red: 0.53, green: 0.45, blue: 0.98)
        static let peach = Color(red: 1.0, green: 0.62, blue: 0.48)
        static let brandGradient = LinearGradient(
            colors: [mint, violet, peach], startPoint: .leading, endPoint: .trailing)
    }

    extension MarketingImages {
        /// Renders the animated hero as numbered PNG frames for `Scripts/make-hero-gif.sh`.
        /// Momo follows the cursor, gets tickled, falls in love, thinks, talks and cheers.
        static func renderHeroFrames(to folder: URL, framesPerSecond: Double = 20) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let engine = FaceEngine(random: FixedRandom())
            engine.isLifeEnabled = false
            let step = 1 / framesPerSecond
            let duration = 8.0
            // (time, what happens)
            var script: [(Double, (FaceEngine) -> Void)] = [
                (0, { $0.setMood(.idle) }),
                (2.0, { $0.poke(atX: 30) }),
                (2.9, { $0.setMood(.love) }),
                (4.2, { $0.setMood(.thinking) }),
                (5.4, { $0.setMood(.speaking) }),
                (6.6, { $0.setMood(.happy) }),
                (7.5, { $0.setMood(.idle) }),
            ]
            // Warm up so springs and blinks are settled on the first frame.
            for _ in 0..<60 { engine.advance(by: step, input: .init(pointer: SIMD2(0, 200))) }
            var time = 0.0
            var index = 0
            while time < duration {
                while let next = script.first, next.0 <= time {
                    next.1(engine)
                    script.removeFirst()
                }
                // An imaginary cursor sweeps across while Momo is idle.
                let pointer = SIMD2(sin(time * 1.4) * 320, 180 + cos(time * 0.9) * 60)
                let face = engine.advance(by: step, input: .init(pointer: pointer))
                let renderer = ImageRenderer(content: Hero(face: face, time: time))
                renderer.scale = 0.6
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: tiff),
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try? png.write(
                        to: folder.appendingPathComponent(String(format: "%04d.png", index)))
                }
                time += step
                index += 1
            }
            print("Rendered \(index) frames to \(folder.path)")
        }
    }

    /// Deterministic randomness so the images don't change between runs.
    private struct FixedRandom: RandomNumberGenerator {
        var state: UInt64 = 7
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Hero

    /// "Meet Momo": a giant notch with Momo hanging from it, the headline and floating cards.
    struct Hero: View {
        var face: FaceState
        /// Seconds into the animation; the floating cards bob with it.
        var time: Double

        private func bob(_ phase: Double) -> Double { sin(time * 1.6 + phase) * 7 }

        var body: some View {
            ZStack(alignment: .top) {
                background
                MarketingImages.Character(
                    state: face, scale: 2.7, notchWidth: 520, notchHeight: 54)
                VStack(spacing: 18) {
                    Spacer().frame(height: 348)
                    HStack(spacing: 22) {
                        Text(verbatim: "Meet")
                            .foregroundStyle(MarketingImages.ink)
                        Text(verbatim: "Momo")
                            .foregroundStyle(MarketingImages.brandGradient)
                    }
                    .font(.system(size: 124, weight: .heavy, design: .rounded))
                    .tracking(-3)
                    Text(verbatim: "Your Mac's little buddy.")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(MarketingImages.ink.opacity(0.78))
                    Text(
                        verbatim:
                            "It lives in your notch, keeps your day on track and thinks on your Mac."
                    )
                    .font(.system(size: 25, weight: .regular, design: .rounded))
                    .foregroundStyle(MarketingImages.ink.opacity(0.55))
                    .padding(.top, 2)
                    HStack(spacing: 14) {
                        Badge(
                            symbol: "lock.fill", text: "Private, local-first",
                            color: MarketingImages.mint)
                        Badge(
                            symbol: "sparkles", text: "Uses the plan you already have",
                            color: MarketingImages.violet)
                        Badge(
                            symbol: "heart.fill", text: "Free & open source",
                            color: MarketingImages.peach)
                    }
                    .padding(.top, 22)
                }
                FloatingCard(
                    icon: "mic.fill", tint: MarketingImages.peach, title: "“Hey Momo, plan my day”",
                    subtitle: "3 tasks · 2 meetings · 1 focus block"
                )
                .rotationEffect(.degrees(-5))
                .offset(x: -540, y: 150 + bob(0))
                FloatingCard(
                    icon: "checkmark.circle.fill", tint: MarketingImages.mint,
                    title: "Call Ayşe · 15:00", subtitle: "Reminder set on this Mac"
                )
                .rotationEffect(.degrees(4))
                .offset(x: 540, y: 110 + bob(2))
                FloatingCard(
                    icon: "brain", tint: MarketingImages.violet, title: "Asking your ChatGPT plan",
                    subtitle: "Names and emails hidden first"
                )
                .rotationEffect(.degrees(-3))
                .offset(x: 575, y: 285 + bob(4))
            }
            .frame(width: 1600, height: 900)
            .clipped()
        }

        private var background: some View {
            ZStack {
                Color(red: 0.985, green: 0.975, blue: 0.965)
                Circle().fill(MarketingImages.mint.opacity(0.35)).frame(width: 700).blur(
                    radius: 140
                )
                .offset(x: -560, y: 420)
                Circle().fill(MarketingImages.violet.opacity(0.30)).frame(width: 760).blur(
                    radius: 150
                )
                .offset(x: 560, y: 380)
                Circle().fill(MarketingImages.peach.opacity(0.30)).frame(width: 620).blur(
                    radius: 150
                )
                .offset(x: 0, y: 620)
            }
        }
    }

    private struct Badge: View {
        var symbol: String
        var text: String
        var color: Color

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(verbatim: text).foregroundStyle(MarketingImages.ink.opacity(0.8))
            }
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(.white.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        }
    }

    private struct FloatingCard: View {
        var icon: String
        var tint: Color
        var title: String
        var subtitle: String

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title).font(
                        .system(size: 20, weight: .semibold, design: .rounded))
                    Text(verbatim: subtitle).font(.system(size: 15, design: .rounded)).opacity(0.6)
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.085, blue: 0.11))
            )
            .shadow(color: .black.opacity(0.22), radius: 26, y: 14)
        }
    }

    // MARK: - Alive

    /// Momo's range of moods and looks on a dark stage.
    private struct AliveBanner: View {
        private let cast: [(Mood, CharacterAppearance, String, Bool)] = [
            (.happy, .classic, "Happy", true),
            (.thinking, .scholar, "Thinking", false),
            (.listening, .snow, "Listening", false),
            (.music, .kitty, "Grooving", true),
            (.sleepy, .robo, "Sleepy", true),
            (.love, .peach, "In love", true),
            (.surprised, .sprout, "Surprised", true),
        ]

        var body: some View {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Text(verbatim: "Alive,").foregroundStyle(.white)
                        Text(verbatim: "not animated.").foregroundStyle(
                            MarketingImages.brandGradient)
                    }
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .tracking(-1.5)
                    Text(
                        verbatim:
                            "Momo breathes, blinks, follows your cursor, giggles when poked and dozes off when you step away."
                    )
                    .font(.system(size: 24, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 70)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, member in
                        VStack(spacing: 10) {
                            ZStack(alignment: .top) {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(.white.opacity(0.06))
                                MarketingImages.Character(
                                    state: MarketingImages.face(member.0, particles: member.3),
                                    appearance: member.1, scale: 1.3
                                )
                                .frame(width: 200, height: 170, alignment: .top)
                                .clipped()
                            }
                            .frame(width: 200, height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            Text(verbatim: member.2)
                                .font(.system(size: 20, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .padding(.top, 56)
                Spacer()
            }
            .frame(width: 1600, height: 540)
            .background(
                ZStack {
                    Color(red: 0.05, green: 0.05, blue: 0.07)
                    Circle().fill(MarketingImages.violet.opacity(0.25)).frame(width: 800).blur(
                        radius: 170
                    )
                    .offset(x: 420, y: 260)
                    Circle().fill(MarketingImages.mint.opacity(0.18)).frame(width: 700).blur(
                        radius: 170
                    )
                    .offset(x: -500, y: 300)
                })
        }
    }

    // MARK: - Brains

    /// The three kinds of brains, each with Momo's eye colour for it.
    private struct BrainsBanner: View {
        var body: some View {
            VStack(spacing: 14) {
                VStack(spacing: 10) {
                    Text(verbatim: "Your Mac first.")
                        .foregroundStyle(MarketingImages.ink)
                    Text(verbatim: "Your subscription when it matters.")
                        .foregroundStyle(MarketingImages.brandGradient)
                }
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .tracking(-1.5)
                Text(
                    verbatim:
                        "Momo's eyes tell you who's thinking. It always asks before anything leaves your Mac."
                )
                .font(.system(size: 24, design: .rounded))
                .foregroundStyle(MarketingImages.ink.opacity(0.55))
                HStack(spacing: 28) {
                    BrainCard(
                        brain: .local, tint: MarketingImages.mint, title: "On your Mac",
                        items: ["Apple Intelligence", "Ollama", "LM Studio"],
                        note: "Private and offline")
                    BrainCard(
                        brain: .subscription, tint: MarketingImages.violet, title: "Your plan",
                        items: ["ChatGPT via Codex", "Gemini CLI"], note: "No extra API bill")
                    BrainCard(
                        brain: .apiKey, tint: MarketingImages.peach, title: "Your keys",
                        items: ["Claude", "OpenAI · Gemini", "OpenRouter"],
                        note: "Stored in your Keychain")
                }
                .padding(.top, 40)
            }
            .padding(.top, 64)
            .frame(width: 1600, height: 820, alignment: .top)
            .background(
                ZStack {
                    Color(red: 0.985, green: 0.975, blue: 0.965)
                    Circle().fill(MarketingImages.violet.opacity(0.22)).frame(width: 700).blur(
                        radius: 150
                    )
                    .offset(x: 0, y: 360)
                })
        }
    }

    private struct BrainCard: View {
        var brain: BrainSource
        var tint: Color
        var title: String
        var items: [String]
        var note: String

        var body: some View {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    Rectangle().fill(tint.opacity(0.14))
                    MarketingImages.Character(
                        state: MarketingImages.face(.idle, brain: brain), scale: 1.25
                    )
                    .frame(width: 440, height: 170, alignment: .top)
                    .clipped()
                }
                .frame(height: 170)
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 10) {
                            Circle().fill(tint).frame(width: 9, height: 9)
                            Text(verbatim: item).font(.system(size: 21, design: .rounded))
                        }
                    }
                    Text(verbatim: note)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(tint)
                        .padding(.top, 6)
                }
                .foregroundStyle(MarketingImages.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(26)
                Spacer(minLength: 0)
            }
            .frame(width: 440, height: 440)
            .background(.white, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 24, y: 12)
        }
    }
#endif
