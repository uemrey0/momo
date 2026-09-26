#if DEBUG
    import AppKit
    import MomoBrain
    import MomoFace
    import MomoKit
    import SwiftUI

    /// Renders the panel and character to PNG files with sample data, for checking the UI
    /// and for README screenshots. Debug builds only:
    ///
    ///     swift run Momo --snapshot ~/Desktop/momo-snapshots
    /// Sends one message through the full assistant stack and prints the reply. Debug builds
    /// only, for testing brains end to end without the UI:
    ///
    ///     swift run Momo --ask "Add milk to my list" --brain-url http://127.0.0.1:1234/v1 --brain-model m
    @MainActor
    enum HeadlessAsk {
        static func runIfRequested() -> Bool {
            let arguments = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                    return nil
                }
                return arguments[index + 1]
            }
            guard let message = value("--ask") else { return false }
            let defaults = UserDefaults(suiteName: "momo-headless") ?? .standard
            defaults.removePersistentDomain(forName: "momo-headless")
            let settings = AppSettings(defaults: defaults)
            if let url = value("--brain-url"), let model = value("--brain-model") {
                settings.preferences.brains.lmStudioURL = url
                settings.preferences.brains.lmStudioModel = model
                settings.preferences.brains.disabled = Set(
                    BrainCatalog.allIDs.filter { $0 != "lmstudio" })
            }
            let store = MomoStore(
                fileURL: URL(
                    fileURLWithPath: value("--data") ?? NSTemporaryDirectory()
                        + "momo-headless.json"))
            let assistant = AssistantController(store: store, settings: settings)
            Task {
                assistant.send(message)
                while assistant.isBusy {
                    if assistant.consentPrompt != nil { assistant.answerConsent(.allowOnce) }
                    if assistant.confirmationPrompt != nil { assistant.answerConfirmation(true) }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                for message in assistant.messages {
                    let tools = message.activities.map { "[\($0.toolName): \($0.state)]" }
                        .joined(separator: " ")
                    print("\(message.role) \(message.brainName ?? ""): \(tools) \(message.text)")
                }
                print("tasks:", await store.tasks().map(\.title))
                exit(0)
            }
            return true
        }
    }

    @MainActor
    enum Snapshots {
        static func renderIfRequested() -> Bool {
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--render-hero-frames"),
                index + 1 < arguments.count
            {
                MarketingImages.renderHeroFrames(to: URL(fileURLWithPath: arguments[index + 1]))
                exit(0)
            }
            if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
                renderIcon(to: URL(fileURLWithPath: arguments[index + 1]))
                exit(0)
            }
            guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count
            else { return false }
            let folder = URL(
                fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            Task {
                await render(to: folder)
                exit(0)
            }
            return true
        }

        private static func render(to folder: URL) async {
            let store = MomoStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("momo-snapshot-\(UUID().uuidString).json"))
            _ = try? await store.addTask(
                title: "Send the invoice to Deniz", dueDate: Date().addingTimeInterval(3 * 3600))
            _ = try? await store.addTask(
                title: "Book the dentist", remindAt: Date().addingTimeInterval(26 * 3600))
            _ = try? await store.addTask(title: "Water the plants")
            if let done = try? await store.addTask(title: "Morning run") {
                _ = try? await store.completeTask(done.id)
            }
            for offset in 0..<5 {
                let day =
                    Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
                _ = try? await store.logHabit("Drink 2 litres of water", on: day)
            }
            _ = try? await store.addHabit(name: "Read 20 pages")
            _ = try? await store.addNote(
                title: "Wi-Fi at the office",
                body: "Network: Momo-Guest\nPassword is on the fridge.")
            _ = try? await store.addNote(
                title: "Gift ideas", body: "Mum: a nice teapot. Emre: a mechanical keyboard.")

            let settings = AppSettings(
                defaults: UserDefaults(suiteName: "momo-snapshots") ?? .standard)
            let assistant = AssistantController(store: store, settings: settings)
            let today = TodayModel(store: store)
            let notes = NotesModel(store: store)
            try? await Task.sleep(for: .milliseconds(300))

            let state = PanelState()
            func panel() -> some View {
                PanelView(
                    assistant: assistant, today: today, notes: notes, state: state,
                    openSettings: {}, close: {}
                )
                .environment(\.snapshotMode, true)
                .padding(24)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.6, blue: 0.75),
                            Color(red: 0.8, green: 0.68, blue: 0.7),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            assistant.messages = [
                ChatMessage(role: .user, text: "Remind me to call Ayşe tomorrow at 3"),
                ChatMessage(
                    role: .assistant,
                    text: "Done! I'll remind you **tomorrow at 15:00** to call Ayşe.",
                    brainName: "Apple Intelligence", brainKind: .local,
                    activities: [ToolActivity(toolName: "add_task", state: .succeeded)]),
                ChatMessage(
                    role: .user,
                    text: "Now review this 30-page rental contract and list the risky clauses"),
                ChatMessage(
                    role: .assistant, text: "", brainName: "ChatGPT (Codex)",
                    brainKind: .subscription,
                    isStreaming: true),
            ]
            save(panel(), "panel-chat", folder)

            let characters = LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(250), spacing: 0), count: 4), spacing: 0
            ) {
                ForEach(CharacterAppearance.builtIns) { look in
                    let face = settle(FaceEngine(), pointer: SIMD2(0, 200))
                    let layout = FaceLayout(topInset: 0, capWidth: 0, scale: 0.75)
                    VStack(spacing: 4) {
                        Canvas { context, _ in
                            FaceRenderer.draw(face, in: &context, layout: layout, appearance: look)
                        }
                        .frame(width: layout.canvasSize.width, height: 78)
                        .clipped()
                        Text(verbatim: look.localizedName(for: "en"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.7))
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.8, green: 0.86, blue: 0.93),
                        Color(red: 0.93, green: 0.87, blue: 0.9),
                    ],
                    startPoint: .top, endPoint: .bottom))
            save(characters, "characters", folder)
            MarketingImages.render(to: folder)

            state.tab = .today
            save(panel(), "panel-today", folder)
            state.tab = .notes
            save(panel(), "panel-notes", folder)

            print("Snapshots written to \(folder.path)")
        }

        /// Runs an engine until it has settled, with the eyes open (not mid-blink).
        static func settle(_ engine: FaceEngine, pointer: SIMD2<Double>? = nil) -> FaceState {
            engine.isLifeEnabled = false
            engine.reducesMotion = true
            let input = FaceEngine.Input(pointer: pointer)
            var face = FaceState.resting
            for _ in 0..<90 { face = engine.advance(by: 1 / 60, input: input) }
            for _ in 0..<600 where face.eyeOpenness < 0.99 {
                face = engine.advance(by: 1 / 60, input: input)
            }
            return face
        }

        /// Renders the 1024 × 1024 app icon: Momo smiling on a soft gradient squircle.
        private static func renderIcon(to url: URL) {
            let engine = FaceEngine()
            engine.isLifeEnabled = false
            engine.setMood(.happy)
            engine.reducesMotion = true
            var face = FaceState.resting
            for _ in 0..<120 { face = engine.advance(by: 1 / 60, input: .init()) }
            let snapshot = face
            // Momo hangs from a notch at the top of the squircle, as it does on the Mac.
            let layout = FaceLayout(topInset: 110, capWidth: 400, scale: 4.3)
            let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)
            let icon = ZStack(alignment: .top) {
                squircle.fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.45, green: 0.91, blue: 0.80),
                            Color(red: 0.62, green: 0.60, blue: 0.98),
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
                Canvas { context, _ in
                    FaceRenderer.draw(snapshot, in: &context, layout: layout)
                }
                .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
            }
            .frame(width: 824, height: 824)
            .clipShape(squircle)
            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            .frame(width: 1024, height: 1024)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: url)
            print("Icon written to \(url.path)")
        }

        static func save(
            _ view: some View, _ name: String, _ folder: URL, jpeg: Bool = false
        ) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let data = bitmap.representation(
                    using: jpeg ? .jpeg : .png,
                    properties: jpeg ? [.compressionFactor: 0.82] : [:])
            else {
                print("Could not render \(name)")
                return
            }
            try? data.write(to: folder.appendingPathComponent("\(name).\(jpeg ? "jpg" : "png")"))
        }
    }
#endif
