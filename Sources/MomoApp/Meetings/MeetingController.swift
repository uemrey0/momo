import AppKit
import EventKit
import MomoBrain
import MomoKit
import MomoVoice
import Observation

/// Takes meeting notes: records the microphone and the call as two tracks, transcribes them
/// chunk by chunk, and when the meeting ends writes the summary, saves the meeting and a
/// note, and offers the action items as tasks.
///
/// Nothing is recorded without the user's yes: every start goes through ``requestStart``,
/// which comes from a button, a notification action or a confirmed tool call. While
/// recording, the character shows a red dot and the menu bar offers to stop. Audio stays in
/// memory unless the user keeps meeting audio. Cloud transcription asks for consent once
/// per meeting (never in local-only mode), and the summary runs through the assistant, so
/// routing, consent and personal data masking apply.
@MainActor
@Observable
final class MeetingController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        /// Recording stopped; the last chunks are transcribed and the summary written.
        case finishing
    }

    /// A question to answer before recording can start.
    enum StartPrompt: Equatable {
        /// System audio needs the Screen Recording permission.
        case systemAudioPermission
        /// The chosen speech engine sends audio to this service.
        case cloudTranscription(service: String)
    }

    enum PermissionAnswer {
        case openSettings
        case microphoneOnly
        case cancel
    }

    enum CloudAnswer {
        case allow
        case onDevice
        case cancel
    }

    /// What a request to start led to.
    enum StartResult: Equatable {
        case started
        /// A question shows in the Meetings tab.
        case waitingForAnswer
        case alreadyRunning
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// The meeting being recorded or finished.
    private(set) var current: Meeting?
    /// Saved meetings, most recent first.
    private(set) var meetings: [Meeting] = []
    private(set) var startPrompt: StartPrompt?
    /// Consent for a remote brain to write a summary.
    private(set) var summaryConsent: ConsentPrompt?
    /// A meeting Momo noticed and offers to take notes of.
    private(set) var offer: MeetingDetector.Offer?
    /// Something the user should know, such as a fallback that was used.
    private(set) var notice: String?
    private(set) var errorMessage: String?
    /// Input levels from 0 to 1, for the live view.
    private(set) var levels: [MeetingTrack: Double] = [:]
    /// Whether the call's audio is recorded too, or only the microphone.
    private(set) var capturesSystemAudio = false
    /// Chunks waiting to be transcribed.
    private(set) var pendingChunks = 0
    /// Meetings whose summary is being written.
    private(set) var summarizing: Set<String> = []
    /// The meeting the Meetings tab shows in detail.
    var selectedMeetingID: String?

    /// Whether Momo is recording or about to.
    var isRecording: Bool { phase == .starting || phase == .recording }

    @ObservationIgnored private let store: MomoStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let calendar: CalendarService
    @ObservationIgnored private weak var assistant: AssistantController?
    @ObservationIgnored private weak var character: CharacterController?
    /// Opens the panel on the Meetings tab.
    @ObservationIgnored var showMeetings: (() -> Void)?
    /// Called when recording starts or stops.
    @ObservationIgnored var onRecordingChanged: (() -> Void)?

    @ObservationIgnored private var pending: PendingStart?
    @ObservationIgnored private var capture: MeetingAudioCapture?
    @ObservationIgnored private var engine: TranscriptionEngine?
    @ObservationIgnored private var router: Task<Void, Never>?
    @ObservationIgnored private var persistence: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var consentContinuation: CheckedContinuation<RemoteConsent, Never>?

    private struct PendingStart {
        var title: String
        var event: CalendarMeeting?
        var microphoneOnly = false
        var onDevice = false
        var approvedCloud = false
    }

    /// The speech engine for one meeting.
    struct TranscriptionEngine: Sendable {
        var service: any AudioTranscriptionService
        var isRemote: Bool
        /// Ask the service for speaker labels (and timed segments).
        var identifiesSpeakers: Bool
        /// Used when a remote request fails, so no part of the meeting is lost.
        var fallback: OnDeviceTranscriptionService?
    }

    init(
        store: MomoStore, settings: AppSettings, calendar: CalendarService,
        assistant: AssistantController, character: CharacterController
    ) {
        self.store = store
        self.settings = settings
        self.calendar = calendar
        self.assistant = assistant
        self.character = character
    }

    /// Follows the store and marks meetings that were interrupted by quitting Momo, so their
    /// summary can be written now.
    func start() {
        observation = Task { [weak self] in
            guard let store = self?.store else { return }
            for await data in await store.changes() {
                self?.meetings = data.meetings.sorted { $0.startedAt > $1.startedAt }
            }
        }
        Task {
            for var meeting in await store.meetings()
            where meeting.status == .recording || meeting.status == .summarizing {
                meeting.status = .failed
                meeting.endedAt =
                    meeting.endedAt
                    ?? meeting.segments.last.map {
                        meeting.startedAt.addingTimeInterval($0.end)
                    }
                meeting.failureReason = L("Momo quit before the summary was written.")
                _ = try? await store.saveMeeting(meeting)
            }
        }
    }

    // MARK: - Starting

    /// Starts taking notes, asking first when system audio needs a permission or the speech
    /// engine would send audio off the Mac. `approvedCloud` is set when the user already
    /// agreed to cloud transcription (a confirmed tool call that said so).
    @discardableResult
    func requestStart(
        title: String? = nil, event: CalendarMeeting? = nil, approvedCloud: Bool = false
    ) async -> StartResult {
        guard phase == .idle else { return .alreadyRunning }
        let event = event ?? currentEvent()
        let title =
            title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? event?.title ?? offer.map { String(format: L("%@ call"), $0.app.name) }
            ?? L("Meeting")
        offer = nil
        pending = PendingStart(title: title, event: event, approvedCloud: approvedCloud)
        return await continueStart()
    }

    private func continueStart() async -> StartResult {
        guard let request = pending else { return .failed(L("Nothing to start.")) }
        if !request.microphoneOnly, !MeetingAudioCapture.hasSystemAudioPermission {
            startPrompt = .systemAudioPermission
            showMeetings?()
            return .waitingForAnswer
        }
        let engine = request.onDevice ? onDeviceEngine() : transcriptionEngine()
        if engine.isRemote, !request.approvedCloud {
            startPrompt = .cloudTranscription(service: engine.service.displayName)
            showMeetings?()
            return .waitingForAnswer
        }
        startPrompt = nil
        pending = nil
        return await begin(request, engine: engine)
    }

    /// Answers the Screen Recording question.
    func answerPermission(_ answer: PermissionAnswer) {
        switch answer {
        case .openSettings:
            MeetingAudioCapture.requestSystemAudioPermission()
            if let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            {
                NSWorkspace.shared.open(url)
            }
        case .microphoneOnly:
            pending?.microphoneOnly = true
            Task { await continueStart() }
        case .cancel:
            cancelStart()
        }
    }

    /// Answers the cloud transcription question.
    func answerCloud(_ answer: CloudAnswer) {
        switch answer {
        case .allow: pending?.approvedCloud = true
        case .onDevice: pending?.onDevice = true
        case .cancel:
            cancelStart()
            return
        }
        Task { await continueStart() }
    }

    private func cancelStart() {
        pending = nil
        startPrompt = nil
    }

    /// Whether starting now would send audio to a cloud service, and which one.
    var cloudServiceName: String? {
        let engine = transcriptionEngine()
        return engine.isRemote ? engine.service.displayName : nil
    }

    private func begin(_ request: PendingStart, engine: TranscriptionEngine) async -> StartResult {
        phase = .starting
        errorMessage = nil
        notice = nil
        let id = ShortID.make()
        let folder =
            settings.preferences.keepsMeetingAudio
            ? AppSettings.meetingsDirectory.appendingPathComponent(id, isDirectory: true) : nil
        let capture = MeetingAudioCapture(
            capturesSystemAudio: !request.microphoneOnly, audioFolder: folder)
        capture.onLevel = { [weak self] track, level in
            Task { @MainActor in self?.levels[track] = level }
        }
        capture.onSystemAudioStopped = { [weak self] error in
            Task { @MainActor in
                self?.notice = String(
                    format: L("Momo can't hear the call any more, only your microphone. %@"),
                    error.localizedDescription)
            }
        }
        character?.isRecordingMeeting = true
        onRecordingChanged?()
        do {
            try await capture.start()
        } catch {
            phase = .idle
            character?.isRecordingMeeting = false
            onRecordingChanged?()
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
        let you = MeetingParticipant(name: L("You"), isUser: true, spoke: false)
        let invited = (request.event?.attendees ?? []).map {
            MeetingParticipant(name: $0, spoke: false)
        }
        let meeting = Meeting(
            id: id, title: request.title, startedAt: Date(),
            calendarEventID: request.event?.id, language: meetingLanguageCode,
            status: .recording, participants: [you] + invited, participantCount: 1)
        current = meeting
        self.capture = capture
        self.engine = engine
        capturesSystemAudio = capture.capturesSystemAudio
        if request.microphoneOnly {
            notice = L("Only your microphone is recorded, so others are heard through it.")
        }
        phase = .recording
        selectedMeetingID = nil
        persist(meeting)
        router = Task { [weak self] in await self?.transcribe(capture.chunks, meetingID: id) }
        return .started
    }

    // MARK: - Transcribing

    /// Transcribes chunks as they arrive, one track after the other within each chunk's turn,
    /// so the network never sees more than one request per track at a time.
    private func transcribe(_ chunks: AsyncStream<MeetingAudioChunk>, meetingID: String) async {
        var workers: [MeetingTrack: AsyncStream<MeetingAudioChunk>.Continuation] = [:]
        await withTaskGroup(of: Void.self) { group in
            for track in MeetingTrack.allCases {
                let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
                workers[track] = continuation
                group.addTask { [weak self] in
                    for await chunk in stream {
                        await self?.transcribe(chunk, meetingID: meetingID)
                    }
                }
            }
            for await chunk in chunks {
                guard
                    AudioChunker.hasSound(
                        chunk.chunk.samples, sampleRate: chunk.chunk.sampleRate)
                else { continue }
                pendingChunks += 1
                workers[chunk.track]?.yield(chunk)
            }
            for continuation in workers.values { continuation.finish() }
        }
    }

    private func transcribe(_ chunk: MeetingAudioChunk, meetingID: String) async {
        defer { pendingChunks = max(0, pendingChunks - 1) }
        guard let engine else { return }
        let clip = AudioClip.wav(samples: chunk.chunk.samples, sampleRate: chunk.chunk.sampleRate)
        let options = TranscriptionOptions(
            language: meetingLanguageCode, wantsSegments: true,
            identifiesSpeakers: engine.identifiesSpeakers)
        if engine.isRemote {
            assistant?.recordOutbound(
                service: engine.service.displayName, audioSeconds: clip.duration)
        }
        let (transcript, failure) = await Self.transcribe(clip, engine: engine, options: options)
        if let failure {
            notice = String(
                format: L(
                    "Cloud transcription failed for part of the meeting, so Momo transcribed it on this Mac. %@"
                ), failure.localizedDescription)
        }
        guard let transcript, var meeting = current, meeting.id == meetingID else { return }
        let segments = transcript.chunkSegments(index: chunk.chunk.index, start: chunk.chunk.start)
            .map { segment in
                MeetingSegment(
                    source: chunk.track == .microphone ? .you : .others,
                    speaker: chunk.track == .system ? segment.speaker : nil, text: segment.text,
                    start: segment.start, end: segment.end)
            }
        guard !segments.isEmpty else { return }
        meeting.segments = MeetingTranscript.merged(meeting.segments + segments)
        if chunk.track == .microphone, let index = meeting.participants.firstIndex(where: \.isUser)
        {
            meeting.participants[index].spoke = true
        }
        if meeting.language == nil, let language = transcript.language, language.count == 2 {
            meeting.language = language
        }
        current = meeting
        persist(meeting)
    }

    /// Sends a clip to the engine's service, off the main actor, falling back to the Mac when
    /// a cloud request fails. Returns the transcript and the cloud error, if there was one.
    private nonisolated static func transcribe(
        _ clip: AudioClip, engine: TranscriptionEngine, options: TranscriptionOptions
    ) async -> (Transcript?, (any Error)?) {
        do {
            return (try await engine.service.transcribe(clip, options: options), nil)
        } catch is CancellationError {
            return (nil, nil)
        } catch {
            guard let fallback = engine.fallback else { return (nil, error) }
            let local = try? await fallback.transcribe(
                clip, options: TranscriptionOptions(wantsSegments: true))
            return (local, error)
        }
    }

    private func transcriptionEngine() -> TranscriptionEngine {
        let preferences = settings.preferences
        let selection = DictationEngineSelector.select(
            preferences.dictationEngine,
            speechAnalyzerAvailable: DictationEngineSelector.isSpeechAnalyzerAvailable,
            hasOpenAIKey: key("openai") != nil, hasGeminiKey: key("gemini-api") != nil)
        guard !preferences.brains.localOnly else { return onDeviceEngine() }
        switch selection.kind {
        case .openAI:
            guard let key = key("openai") else { return onDeviceEngine() }
            // Diarization labels the call's speakers and times every segment, for both tracks.
            return TranscriptionEngine(
                service: OpenAITranscriptionService(apiKey: key, model: .gpt4oTranscribeDiarize),
                isRemote: true, identifiesSpeakers: true, fallback: onDeviceService)
        case .gemini:
            guard let key = key("gemini-api") else { return onDeviceEngine() }
            return TranscriptionEngine(
                service: GeminiTranscriptionService(apiKey: key), isRemote: true,
                identifiesSpeakers: true, fallback: onDeviceService)
        case .appleSpeech, .speechAnalyzer:
            return onDeviceEngine()
        }
    }

    private func onDeviceEngine() -> TranscriptionEngine {
        TranscriptionEngine(
            service: onDeviceService, isRemote: false, identifiesSpeakers: false, fallback: nil)
    }

    private var onDeviceService: OnDeviceTranscriptionService {
        let code = meetingLanguageCode
        let locale =
            code == nil || code == Locale.current.language.languageCode?.identifier
            ? Locale.current : Locale(identifier: code ?? "en")
        return OnDeviceTranscriptionService(locale: locale)
    }

    /// The meeting language from Settings, or `nil` to follow the system (and let cloud
    /// services detect it).
    private var meetingLanguageCode: String? {
        let code = settings.preferences.meetingLanguage
        return code.isEmpty ? nil : code
    }

    private func key(_ providerID: String) -> String? {
        guard let key = settings.keys.key(for: providerID), !key.isEmpty else { return nil }
        return key
    }

    // MARK: - Stopping

    /// Stops recording. The last chunks are transcribed and the summary is written in the
    /// background; the meeting stays visible in the Meetings tab meanwhile. Returns whether
    /// anything was recording.
    @discardableResult
    func stop() -> Bool {
        guard phase == .recording, let capture else { return false }
        phase = .finishing
        let endedAt = Date()
        Task {
            await capture.stop()
            character?.isRecordingMeeting = false
            levels = [:]
            onRecordingChanged?()
            await router?.value
            router = nil
            self.capture = nil
            engine = nil
            guard var meeting = current else {
                phase = .idle
                return
            }
            meeting.endedAt = endedAt
            meeting.segments = MeetingTranscript.removingEcho(meeting.segments)
            current = nil
            phase = .idle
            selectedMeetingID = meeting.id
            await summarize(meeting)
        }
        return true
    }

    // MARK: - Summaries

    /// Writes (or rewrites) a meeting's notes and saves them, with a note in Notes.
    func summarize(_ meeting: Meeting) async {
        guard !summarizing.contains(meeting.id), let assistant else { return }
        summarizing.insert(meeting.id)
        defer { summarizing.remove(meeting.id) }
        var meeting = meeting
        meeting.status = .summarizing
        meeting.failureReason = nil
        persist(meeting)
        guard !meeting.segments.isEmpty else {
            meeting.status = .failed
            meeting.failureReason = L("Nothing was transcribed, so there is nothing to summarise.")
            persist(meeting)
            return
        }
        character?.showWorking()
        let attendees = meeting.participants.filter { !$0.isUser && !$0.spoke }.map(\.name)
        let context = MeetingContext(
            title: meeting.title, startedAt: meeting.startedAt, attendees: attendees,
            language: meeting.language)
        let brain = assistant.backgroundBrain { [weak self] brain, reason, masked in
            await self?.askSummaryConsent(brain: brain, reason: reason, masked: masked) ?? .cancel
        }
        do {
            let notes = try await MeetingSummarizer.summarize(
                lines: MeetingTranscript.lines(meeting.segments), context: context,
                maxCharacters: assistant.backgroundRequestBudget, complete: brain)
            apply(notes, to: &meeting, attendees: attendees)
            meeting.status = .done
            meeting.noteID = await saveNote(for: meeting)
            persist(meeting)
            character?.showDone()
        } catch {
            meeting.status = .failed
            meeting.failureReason =
                error is CancellationError
                ? L("The summary was cancelled.") : error.localizedDescription
            persist(meeting)
            character?.showIdle()
        }
    }

    private func apply(_ notes: MeetingNotes, to meeting: inout Meeting, attendees: [String]) {
        meeting.summary = notes.summary
        meeting.decisions = notes.decisions
        meeting.actionItems = notes.actionItems
        meeting.openQuestions = notes.openQuestions
        meeting.language = notes.language ?? meeting.language
        meeting.segments = MeetingTranscript.applying(
            names: notes.speakerNames, to: meeting.segments)
        let spokenNames =
            notes.participants
            + meeting.segments.compactMap(\.speakerName)
        let userSpoke = meeting.segments.contains { $0.source == .you }
        meeting.participants = MeetingParticipants.list(
            userName: L("You"), userSpoke: userSpoke, spokenNames: spokenNames,
            attendees: attendees)
        meeting.participantCount = MeetingParticipants.count(
            segments: meeting.segments, names: notes.participants,
            inferred: notes.participantCount)
    }

    /// Saves the notes as a note titled "Meeting: <title> — <date>", replacing the note of an
    /// earlier summary of the same meeting.
    private func saveNote(for meeting: Meeting) async -> String? {
        let body = meeting.noteBody(
            headings: MeetingNoteHeadings(
                decisions: L("Decisions"), actionItems: L("Action items"),
                openQuestions: L("Open questions"),
                participantsFormat: L("Participants (%ld)")))
        var note = Note(title: meeting.noteTitle, body: body, createdAt: meeting.startedAt)
        if let id = meeting.noteID, await store.notes().contains(where: { $0.id == id }) {
            note.id = id
        }
        return try? await store.saveNote(note).id
    }

    private func askSummaryConsent(
        brain: ProviderInfo, reason: RoutingReason, masked: Bool
    ) async -> RemoteConsent {
        // One question at a time; a second summary waits for the first answer.
        while consentContinuation != nil {
            try? await Task.sleep(for: .milliseconds(300))
        }
        character?.showCurious()
        showMeetings?()
        return await withCheckedContinuation { continuation in
            consentContinuation = continuation
            summaryConsent = ConsentPrompt(brain: brain, reason: reason, masksData: masked)
        }
    }

    func answerSummaryConsent(_ answer: RemoteConsent) {
        summaryConsent = nil
        consentContinuation?.resume(returning: answer)
        consentContinuation = nil
        if answer != .cancel { character?.showWorking() }
    }

    // MARK: - Meetings

    /// Adds action items to the task list: one, or all that aren't tasks yet.
    func addActionItemsAsTasks(_ meeting: Meeting, item: MeetingActionItem? = nil) {
        let ids = item.map { Set([$0.id]) }
        Task {
            let added = try? await store.addActionItemsAsTasks(meetingID: meeting.id, itemIDs: ids)
            if added?.isEmpty == false { character?.celebrate() }
        }
    }

    func delete(_ meeting: Meeting) {
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        let folder = AppSettings.meetingsDirectory.appendingPathComponent(meeting.id)
        Task {
            _ = try? await store.deleteMeeting(meeting.id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Saves meetings one after another, in order.
    private func persist(_ meeting: Meeting) {
        let previous = persistence
        let store = store
        persistence = Task {
            await previous?.value
            _ = try? await store.saveMeeting(meeting)
        }
    }

    // MARK: - Offers

    /// Offers to take notes of a meeting Momo noticed. The user decides; nothing starts here.
    func offer(_ offer: MeetingDetector.Offer) {
        guard phase == .idle, startPrompt == nil else { return }
        self.offer = offer
        character?.showCurious()
    }

    func dismissOffer() {
        offer = nil
    }

    /// The calendar event in progress or about to start, if any.
    func currentEvent(now: Date = Date()) -> CalendarMeeting? {
        let events = calendar.events(
            from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(10 * 60)
        )
        .map(CalendarService.meeting(from:))
        return MeetingDetector.currentEvent(in: events, at: now)
    }
}
