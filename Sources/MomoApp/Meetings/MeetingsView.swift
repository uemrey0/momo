import MomoKit
import MomoVoice
import SwiftUI

/// The Meetings tab: the meeting being recorded with its live transcript, questions Momo
/// needs answered, and past meetings with their notes.
struct MeetingsView: View {
    var controller: MeetingController
    @State private var contentHeight: CGFloat = 0

    private var selected: Meeting? {
        controller.selectedMeetingID.flatMap { id in controller.meetings.first { $0.id == id } }
    }

    var body: some View {
        ZStack {
            if let meeting = selected {
                MeetingDetailView(meeting: meeting, controller: controller)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .preference(key: PanelHeightKey.self, value: 560)
            } else {
                PanelScroll {
                    overview
                        .padding(16)
                        .measureHeight($contentHeight)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .preference(key: PanelHeightKey.self, value: max(240, contentHeight))
            }
        }
        .animation(Theme.spring, value: controller.selectedMeetingID)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            prompts
            if controller.phase == .idle {
                if let offer = controller.offer {
                    OfferCard(offer: offer, controller: controller)
                } else if controller.startPrompt == nil {
                    StartCard(controller: controller)
                }
            } else {
                LiveMeetingCard(controller: controller)
            }
            if let error = controller.errorMessage {
                MeetingNotice(
                    text: error, systemImage: "exclamationmark.triangle.fill", color: Theme.danger)
            }
            if let notice = controller.notice {
                MeetingNotice(text: notice, systemImage: "info.circle.fill", color: Theme.apiKey)
            }
            pastMeetings
        }
        .animation(Theme.spring, value: controller.phase)
        .animation(Theme.spring, value: controller.startPrompt)
        .animation(Theme.spring, value: controller.summaryConsent)
        .animation(Theme.spring, value: controller.offer)
    }

    @ViewBuilder
    private var prompts: some View {
        if let prompt = controller.summaryConsent {
            ConsentCard(prompt: prompt) { controller.answerSummaryConsent($0) }
                .transition(.opacity.combined(with: .offset(y: -6)))
        }
        switch controller.startPrompt {
        case .systemAudioPermission:
            QuestionCard(
                systemImage: "rectangle.dashed.badge.record",
                title: L("Let Momo hear the call?"),
                text: L(
                    "To tell you and the others apart, Momo records the call's audio separately. macOS calls this Screen Recording; Momo only captures sound, never your screen. After allowing it in System Settings, quit and reopen Momo."
                )
            ) {
                Button(L("Open System Settings")) { controller.answerPermission(.openSettings) }
                    .buttonStyle(.borderedProminent)
                Button(L("Microphone only")) { controller.answerPermission(.microphoneOnly) }
                Spacer()
                Button(L("Cancel")) { controller.answerPermission(.cancel) }.buttonStyle(
                    .borderless)
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
        case .cloudTranscription(let service):
            QuestionCard(
                systemImage: "cloud",
                title: String(format: L("Transcribe with %@?"), service),
                text: L(
                    "The meeting's audio is sent in short pieces to this service with your API key while Momo takes notes, and each piece is listed in Privacy. Or Momo can transcribe everything on this Mac."
                )
            ) {
                Button(L("Use the cloud")) { controller.answerCloud(.allow) }
                    .buttonStyle(.borderedProminent)
                Button(L("On this Mac")) { controller.answerCloud(.onDevice) }
                Spacer()
                Button(L("Cancel")) { controller.answerCloud(.cancel) }.buttonStyle(.borderless)
            }
            .transition(.opacity.combined(with: .offset(y: -6)))
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var pastMeetings: some View {
        let past = controller.meetings.filter { $0.id != controller.current?.id }
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: L("Past meetings"), systemImage: "clock.fill", count: past.count)
            if past.isEmpty {
                EmptyHint(
                    systemImage: "person.2.wave.2.fill",
                    text: L(
                        "Meetings Momo took notes of show up here, with their summary and action items."
                    ))
            } else {
                VStack(spacing: 0) {
                    ForEach(past) { meeting in
                        Button {
                            controller.selectedMeetingID = meeting.id
                        } label: {
                            MeetingRow(
                                meeting: meeting,
                                isSummarizing: controller.summarizing.contains(meeting.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L("Delete"), role: .destructive) { controller.delete(meeting) }
                        }
                        if meeting.id != past.last?.id {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

// MARK: - Starting

private struct StartCard: View {
    var controller: MeetingController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: L("Meeting notes"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(
                    verbatim: L(
                        "I'll listen to you and the call, then write a summary with decisions and action items when you stop."
                    )
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                Task { await controller.requestStart() }
            } label: {
                Label(L("Start"), systemImage: "record.circle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.userBubble, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct OfferCard: View {
    var offer: MeetingDetector.Offer
    var controller: MeetingController

    var body: some View {
        QuestionCard(
            systemImage: "person.2.wave.2.fill",
            title: L("Should I take notes?"),
            text: offer.event.map {
                String(format: L("“%@” seems to have started in %@."), $0.title, offer.app.name)
            } ?? String(format: L("A call seems to have started in %@."), offer.app.name)
        ) {
            Button(L("Take notes")) { Task { await controller.requestStart(event: offer.event) } }
                .buttonStyle(.borderedProminent)
            Button(L("Not now")) { controller.dismissOffer() }
            Spacer()
        }
    }
}

// MARK: - Recording

private struct LiveMeetingCard: View {
    var controller: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingBadge(isRecording: controller.isRecording)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: controller.current?.title ?? L("Meeting"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    status
                }
                Spacer()
                if controller.phase == .recording {
                    Button {
                        controller.stop()
                    } label: {
                        Label(L("Stop"), systemImage: "stop.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.danger.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if controller.phase == .recording {
                HStack(spacing: 12) {
                    LevelMeter(title: L("You"), level: controller.levels[.microphone] ?? 0)
                    if controller.capturesSystemAudio {
                        LevelMeter(title: L("Others"), level: controller.levels[.system] ?? 0)
                    }
                }
            }
            let segments = controller.current?.segments.suffix(8) ?? []
            if segments.isEmpty {
                Text(verbatim: L("The transcript appears here, about half a minute behind."))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        TranscriptLine(segment: segment)
                    }
                }
            }
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [Theme.danger.opacity(0.12), Theme.card], startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.25)))
    }

    @ViewBuilder
    private var status: some View {
        Group {
            if controller.phase == .finishing {
                Text(verbatim: L("Finishing the transcript…"))
            } else if let start = controller.current?.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(
                        verbatim: String(
                            format: L("Taking notes · %@"),
                            Duration.seconds(max(0, timeline.date.timeIntervalSince(start)))
                                .formatted(.time(pattern: .minuteSecond))))
                }
            } else {
                Text(verbatim: L("Getting ready…"))
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct RecordingBadge: View {
    var isRecording: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(isRecording ? Theme.danger : Theme.secondaryText)
            .frame(width: 10, height: 10)
            .opacity(isRecording && isPulsing ? 0.4 : 1)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isPulsing
            )
            .onAppear { isPulsing = true }
            .accessibilityLabel(L("Taking meeting notes"))
    }
}

private struct LevelMeter: View {
    var title: String
    var level: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Capsule()
                .fill(Theme.card)
                .frame(width: 70, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent).frame(
                        width: 70 * min(1, max(0.02, level)), height: 4)
                }
                .animation(.easeOut(duration: 0.1), value: level)
        }
    }
}

// MARK: - Past meetings

private struct MeetingRow: View {
    var meeting: Meeting
    var isSummarizing: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: meeting.title.isEmpty ? L("Meeting") : meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: MeetingFormat.details(meeting))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSummarizing || meeting.status == .summarizing {
                ProgressView().controlSize(.mini)
            } else if meeting.status == .failed {
                Pill(text: L("No summary"), color: Theme.apiKey)
            } else if !meeting.actionItems.isEmpty {
                Pill(
                    text: String(format: L("%lld actions"), meeting.actionItems.count),
                    color: Theme.accent, systemImage: "checklist")
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A meeting with its notes and transcript.
private struct MeetingDetailView: View {
    var meeting: Meeting
    var controller: MeetingController
    @State private var showsTranscript = false
    @Environment(\.snapshotMode) private var snapshotMode

    private var pendingItems: [MeetingActionItem] {
        meeting.actionItems.filter { $0.taskID == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    controller.selectedMeetingID = nil
                } label: {
                    Label(L("Meetings"), systemImage: "chevron.left")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                Spacer()
                if snapshotMode {
                    moreIcon
                } else {
                    Menu {
                        Button(L("Summarize again")) {
                            Task { await controller.summarize(meeting) }
                        }
                        .disabled(
                            controller.summarizing.contains(meeting.id) || meeting.segments.isEmpty)
                        Divider()
                        Button(L("Delete"), role: .destructive) { controller.delete(meeting) }
                    } label: {
                        moreIcon
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            PanelScroll {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let prompt = controller.summaryConsent {
                        ConsentCard(prompt: prompt) { controller.answerSummaryConsent($0) }
                    }
                    statusLine
                    if meeting.untranscribedChunks > 0 {
                        MeetingNotice(
                            text: String(
                                format: L(
                                    "Gaps in the transcript: %ld. These notes may miss part of the meeting."
                                ), meeting.untranscribedChunks),
                            systemImage: "waveform.badge.exclamationmark", color: Theme.apiKey)
                    }
                    if !meeting.summary.isEmpty {
                        Text(verbatim: meeting.summary)
                            .font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    list(
                        L("Decisions"), systemImage: "checkmark.seal.fill", items: meeting.decisions
                    )
                    actionItems
                    list(
                        L("Open questions"), systemImage: "questionmark.circle.fill",
                        items: meeting.openQuestions)
                    participants
                    transcript
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private var moreIcon: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 28, height: 28)
            .background(Theme.card, in: Circle())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: meeting.title.isEmpty ? L("Meeting") : meeting.title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .textSelection(.enabled)
            Text(verbatim: MeetingFormat.details(meeting))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if controller.summarizing.contains(meeting.id) || meeting.status == .summarizing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: L("Writing the summary…"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        } else if meeting.status == .failed {
            VStack(alignment: .leading, spacing: 8) {
                MeetingNotice(
                    text: meeting.failureReason ?? L("No summary was written."),
                    systemImage: "exclamationmark.triangle.fill", color: Theme.apiKey)
                if !meeting.segments.isEmpty {
                    Button(L("Write the summary")) { Task { await controller.summarize(meeting) } }
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, systemImage: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: title, systemImage: systemImage, count: items.count)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Circle().fill(Theme.accent.opacity(0.7)).frame(width: 5, height: 5)
                        Text(verbatim: item)
                            .font(.system(size: 12.5))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        if !meeting.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(
                        title: L("Action items"), systemImage: "checklist",
                        count: meeting.actionItems.count)
                    Spacer()
                    if !pendingItems.isEmpty {
                        Button {
                            controller.addActionItemsAsTasks(meeting)
                        } label: {
                            Label(L("Add as tasks"), systemImage: "plus.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(meeting.actionItems) { item in
                        ActionItemRow(item: item) {
                            controller.addActionItemsAsTasks(meeting, item: item)
                        }
                        if item.id != meeting.actionItems.last?.id {
                            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var participants: some View {
        if !meeting.participants.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(
                    title: L("Participants"), systemImage: "person.2.fill",
                    count: meeting.participantCount)
                FlowLayout(spacing: 6) {
                    ForEach(meeting.participants, id: \.name) { person in
                        Pill(
                            text: person.name,
                            color: person.isUser
                                ? Theme.accent
                                : (person.spoke ? Theme.subscription : Theme.tertiaryText),
                            systemImage: person.spoke ? nil : "envelope")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if !meeting.segments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(Theme.spring) { showsTranscript.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showsTranscript ? 90 : 0))
                        Text(verbatim: L("Transcript"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsTranscript {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(meeting.segments.enumerated()), id: \.offset) { _, segment in
                            TranscriptLine(segment: segment, showsTime: true)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

private struct ActionItemRow: View {
    var item: MeetingActionItem
    var add: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.taskID != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .help(L("Added to your tasks"))
            } else {
                Button(action: add) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help(L("Add as a task"))
                .accessibilityLabel(L("Add as a task"))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                let details = [
                    item.owner,
                    item.dueDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
                        ?? item.dueText,
                ]
                .compactMap { $0 }
                if !details.isEmpty {
                    Text(verbatim: details.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .padding(.vertical, 8)
    }
}

// MARK: - Shared pieces

/// One line of a transcript: who spoke (you or others, told apart by colour) and what.
private struct TranscriptLine: View {
    var segment: MeetingSegment
    var showsTime = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsTime {
                Text(verbatim: MeetingTranscript.timestamp(segment.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
            }
            Text(verbatim: MeetingFormat.speaker(of: segment))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(segment.source == .you ? Theme.accent : Theme.subscription)
            Text(verbatim: segment.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct SectionTitle: View {
    var title: String
    var systemImage: String
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(verbatim: title).font(.system(size: 14, weight: .bold, design: .rounded))
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.card, in: Capsule())
            }
        }
    }
}

/// A question with buttons, in the style of the chat's consent card.
private struct QuestionCard<Buttons: View>: View {
    var systemImage: String
    var title: String
    var text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(Theme.accent)
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
            }
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons }
                .controlSize(.small)
        }
        .padding(12)
        .background(Theme.cardStrong, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MeetingNotice: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(verbatim: text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lays out pills in rows, wrapping when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Words and numbers shown about meetings.
enum MeetingFormat {
    /// "Yesterday, 09:30 · 25 min · 4 people"
    static func details(_ meeting: Meeting) -> String {
        var parts = [meeting.startedAt.formatted(date: .abbreviated, time: .shortened)]
        let minutes = Int((meeting.duration() / 60).rounded())
        if meeting.endedAt != nil { parts.append(String(format: L("%lld min"), max(1, minutes))) }
        if meeting.participantCount > 0 {
            parts.append(String(format: L("%lld people"), meeting.participantCount))
        }
        return parts.joined(separator: " · ")
    }

    /// Who said a segment, for the transcript.
    static func speaker(of segment: MeetingSegment) -> String {
        switch segment.source {
        case .you: return L("You")
        case .others:
            if let name = segment.speakerName, !name.isEmpty { return name }
            if let label = segment.speaker { return String(format: L("Speaker %@"), label) }
            return L("Others")
        }
    }
}
