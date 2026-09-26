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
            let meetings = MeetingController(
                store: store, settings: settings, calendar: CalendarService(),
                assistant: assistant, character: CharacterController())
            func panel() -> some View {
                PanelView(
                    assistant: assistant, today: today, notes: notes, meetings: meetings,
                    state: state, openSettings: { _ in }, close: {}
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

            let now = Date()
            func step(
                _ name: String, _ detail: String? = nil, _ state: ToolActivity.State = .succeeded,
                seconds: TimeInterval = 1.2, permission: MacPermission? = nil
            ) -> ToolActivity {
                var activity = ToolActivity(toolName: name, state: state, detail: detail)
                activity.startedAt = now
                activity.finishedAt = state == .running ? nil : now.addingTimeInterval(seconds)
                activity.missingPermission = permission
                return activity
            }
            func reply(
                _ parts: [Any], artifacts: [ChatArtifact] = [], streaming: Bool = false,
                seconds: TimeInterval = 9
            ) -> ChatMessage {
                var message = ChatMessage(role: .assistant, text: "", isStreaming: streaming)
                message.date = now.addingTimeInterval(-seconds)
                for part in parts {
                    if let text = part as? String { message.appendText(text) }
                    if let activity = part as? ToolActivity { message.appendStep(activity) }
                }
                message.artifacts = artifacts
                message.finishedAt = streaming ? nil : now
                return message
            }

            // A finished answer with its work folded away, and a picture Momo drew.
            let picture = Self.samplePicture()
            assistant.messages = [
                ChatMessage(role: .user, text: "Remind me to call Ayşe tomorrow at 3"),
                reply(
                    [
                        step("add_task", "Call Ayşe", seconds: 0.4),
                        "Done! I'll remind you **tomorrow at 15:00** to call Ayşe.",
                    ], seconds: 2),
                ChatMessage(role: .user, text: "Draw Momo relaxing on a beach at sunset"),
                reply(
                    [
                        "Let me paint that for you.",
                        step("generate_image", "Momo relaxing on a beach at sunset", seconds: 7.8),
                        "Here's Momo, soaking up the last of the sun. 🌅",
                    ], artifacts: picture.map { [ChatArtifact(url: $0, kind: .image)] } ?? [],
                    seconds: 11),
            ]
            save(panel(), "panel-chat", folder)

            // Momo at work: what it is doing now, and the steps so far.
            assistant.messages = [
                ChatMessage(
                    role: .user,
                    text:
                        "Find this week's weather for Istanbul and add a reminder for the rainy day"
                ),
                reply(
                    [
                        "I'll check the forecast first.",
                        step("get_weather", "Istanbul", seconds: 0.9),
                        step("web_search", "İstanbul hafta sonu yağmur", seconds: 1.6),
                        "Thursday looks rainy, so I'll set the reminder for Wednesday evening.",
                        step("add_task", "Take an umbrella", .running),
                    ], streaming: true, seconds: 6),
            ]
            save(panel(), "panel-chat-working", folder)

            // Problems, explained with the way out.
            assistant.messages = [
                ChatMessage(role: .user, text: "What's on my calendar today?"),
                reply(
                    [
                        step(
                            "calendar_events", "Today", .failed, seconds: 0.2,
                            permission: .calendars),
                        "I can't see your calendar yet.",
                    ], seconds: 1),
                ChatMessage(role: .user, text: "Summarise the news"),
                ChatMessage(
                    role: .error,
                    text: "Rate limit or quota reached (429). Try again shortly.",
                    issue: ChatIssue(
                        message: "Rate limit or quota reached (429). Try again shortly.")),
            ]
            save(panel(), "panel-chat-help", folder)

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

            let meeting = sampleMeeting()
            _ = try? await store.saveMeeting(meeting)
            meetings.start()
            try? await Task.sleep(for: .milliseconds(300))
            state.tab = .meetings
            save(panel(), "panel-meetings", folder)
            meetings.selectedMeetingID = meeting.id
            save(panel(), "panel-meeting", folder)

            print("Snapshots written to \(folder.path)")
        }

        /// A finished stand-up with notes, for the Meetings tab.
        private static func sampleMeeting() -> Meeting {
            let start = Date().addingTimeInterval(-26 * 3600)
            return Meeting(
                title: "Weekly stand-up", startedAt: start,
                endedAt: start.addingTimeInterval(1_260),
                language: "en", status: .done,
                participants: [
                    MeetingParticipant(name: "You", isUser: true),
                    MeetingParticipant(name: "Ayşe Yılmaz"), MeetingParticipant(name: "Deniz"),
                    MeetingParticipant(name: "Can", spoke: false),
                ],
                participantCount: 3,
                segments: [
                    MeetingSegment(
                        source: .you, text: "Morning! Shall we start?", start: 2, end: 4),
                    MeetingSegment(
                        source: .others, speaker: "1A", speakerName: "Ayşe Yılmaz",
                        text: "Yes. The beta build is ready for testing.", start: 5, end: 8),
                    MeetingSegment(
                        source: .others, speaker: "1B", text: "I still need the release notes.",
                        start: 9, end: 11),
                ],
                summary:
                    "The team reviewed the beta. Testing starts on Monday, and the release moves to the week after if the crash on older Macs isn't fixed by Thursday.",
                decisions: ["Start beta testing on Monday", "Keep the launch date for now"],
                actionItems: [
                    MeetingActionItem(
                        text: "Write the release notes", owner: "You", dueText: "Friday"),
                    MeetingActionItem(
                        text: "Fix the crash on macOS 14", owner: "Deniz", taskID: "done"),
                ],
                openQuestions: ["Who presents the demo?"])
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
                let png = bitmap.representation(
                    using: NSBitmapImageRep.FileType.png, properties: [:])
            else { return }
            try? png.write(to: url)
            print("Icon written to \(url.path)")
        }

        /// A small picture for the sample answer: Momo on a sunset beach, drawn with SwiftUI.
        static func samplePicture() -> URL? {
            let face = settle(FaceEngine(), pointer: SIMD2(0, 200))
            let layout = FaceLayout(topInset: 0, capWidth: 0, scale: 1.3)
            let scene = ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [
                        Color(red: 0.98, green: 0.55, blue: 0.4),
                        Color(red: 0.99, green: 0.78, blue: 0.5),
                        Color(red: 0.45, green: 0.72, blue: 0.9),
                    ], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.9, blue: 0.6)).frame(width: 150)
                    .offset(y: -150)
                Rectangle().fill(Color(red: 0.97, green: 0.87, blue: 0.66)).frame(height: 130)
                Canvas { context, _ in FaceRenderer.draw(face, in: &context, layout: layout) }
                    .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                    .offset(y: -70)
            }
            .frame(width: 720, height: 480)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(
                    using: NSBitmapImageRep.FileType.png, properties: [:])
            else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "momo-sample-beach.png")
            try? png.write(to: url)
            return url
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
