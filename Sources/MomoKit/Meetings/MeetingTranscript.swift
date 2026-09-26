import Foundation

/// Helpers for a meeting's transcript: merging the two audio tracks, removing the echo of
/// the call in the microphone, naming speakers and writing the transcript for a model.
///
/// Speaker labels come from the transcription service, one request (chunk of audio) at a
/// time, so a label is a chunk number followed by the service's letter: "3A" is speaker A of
/// the third chunk. The same person usually gets different labels in different chunks; the
/// summary step matches labels to names (see ``MeetingSummarizer``).
public enum MeetingTranscript {
    /// Merges segments from both tracks into one timeline, keeping the order of segments that
    /// start at the same time.
    public static func merged(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// Removes microphone segments that only repeat what someone in the call said at the same
    /// time: without headphones the microphone hears the Mac's speakers too.
    ///
    /// A microphone segment counts as an echo when at least `threshold` of its words appear
    /// in "others" segments that overlap it in time (with a little slack for timing).
    public static func removingEcho(
        _ segments: [MeetingSegment], threshold: Double = 0.7, slack: TimeInterval = 2
    ) -> [MeetingSegment] {
        let others = segments.filter { $0.source == .others }
        guard !others.isEmpty else { return segments }
        return segments.filter { segment in
            guard segment.source == .you else { return true }
            let words = Self.words(segment.text)
            guard words.count >= 3 else { return true }
            let heard = others.filter {
                $0.start <= segment.end + slack && $0.end >= segment.start - slack
            }
            guard !heard.isEmpty else { return true }
            let otherWords = Set(heard.flatMap { Self.words($0.text) })
            let shared = words.filter { otherWords.contains($0) }.count
            return Double(shared) / Double(words.count) < threshold
        }
    }

    /// Lowercased words without punctuation, for comparing texts.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Applies names the summary step matched to speaker labels ("3A" → "Ayşe"). Labels may be
    /// given with or without the "Speaker " prefix.
    public static func applying(
        names: [String: String], to segments: [MeetingSegment]
    ) -> [MeetingSegment] {
        guard !names.isEmpty else { return segments }
        var lookup: [String: String] = [:]
        for (label, name) in names {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            lookup[normalizedLabel(label)] = cleaned
        }
        return segments.map { segment in
            guard segment.source == .others, let speaker = segment.speaker,
                let name = lookup[normalizedLabel(speaker)]
            else { return segment }
            var named = segment
            named.speakerName = name
            return named
        }
    }

    /// "Speaker 3a" → "3A".
    static func normalizedLabel(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("speaker") {
            text = String(text.dropFirst("speaker".count))
        }
        return text.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            .uppercased()
    }

    /// Who said a segment, for a model: "You", the speaker's name, "Speaker 3A" or "Others".
    public static func speaker(of segment: MeetingSegment) -> String {
        switch segment.source {
        case .you: return "You"
        case .others:
            if let name = segment.speakerName, !name.isEmpty { return name }
            if let label = segment.speaker, !label.isEmpty { return "Speaker \(label)" }
            return "Others"
        }
    }

    /// The transcript as lines for a model: "[04:12] You: Let's start."
    public static func lines(_ segments: [MeetingSegment]) -> [String] {
        merged(segments).map { "[\(timestamp($0.start))] \(speaker(of: $0)): \($0.text)" }
    }

    /// "04:12", or "1:04:12" after an hour.
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}

/// Counts and names the people in a meeting.
public enum MeetingParticipants {
    /// How many other people were heard, at least: the most distinct speaker labels in any one
    /// chunk, or the number of distinct names when speakers were named. Others heard without
    /// speaker labels count as one.
    public static func othersHeard(in segments: [MeetingSegment]) -> Int {
        let others = segments.filter { $0.source == .others }
        guard !others.isEmpty else { return 0 }
        let names = Set(
            others.compactMap { $0.speakerName?.lowercased() }.filter { !$0.isEmpty })
        var labelsByChunk: [String: Set<String>] = [:]
        for segment in others where segment.speakerName == nil {
            guard let label = segment.speaker, !label.isEmpty else { continue }
            let chunk = String(label.prefix(while: \.isNumber))
            labelsByChunk[chunk, default: []].insert(label)
        }
        // An unnamed label may belong to someone named elsewhere, so the two only bound the
        // count from below.
        let unnamedPerChunk = labelsByChunk.values.map(\.count).max() ?? 0
        return max(1, names.count, unnamedPerChunk)
    }

    /// The number of people in the meeting, the user included: what was heard, raised to the
    /// count the summary step inferred or the names it found, when those are larger.
    public static func count(
        segments: [MeetingSegment], names: [String] = [], inferred: Int? = nil
    ) -> Int {
        let heard = othersHeard(in: segments)
        let named = Set(names.map { $0.lowercased() }).count
        return 1 + max(heard, named, (inferred ?? 0) - 1)
    }

    /// The participant list: the user, the people the summary named, then invited attendees
    /// who were not heard. An attendee whose name starts with a spoken name ("Ayşe" and
    /// "Ayşe Yılmaz") is the same person and keeps the fuller name.
    public static func list(
        userName: String, userSpoke: Bool, spokenNames: [String], attendees: [String]
    ) -> [MeetingParticipant] {
        var result = [MeetingParticipant(name: userName, isUser: true, spoke: userSpoke)]
        func matches(_ a: String, _ b: String) -> Bool {
            let a = a.lowercased()
            let b = b.lowercased()
            return a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
        }
        var remainingAttendees = attendees.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        for name in spokenNames {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != "you",
                !result.contains(where: { matches($0.name, name) })
            else { continue }
            if let index = remainingAttendees.firstIndex(where: { matches($0, name) }) {
                let full = remainingAttendees.remove(at: index)
                result.append(MeetingParticipant(name: full.count > name.count ? full : name))
            } else {
                result.append(MeetingParticipant(name: name))
            }
        }
        for attendee in remainingAttendees
        where !result.contains(where: { matches($0.name, attendee) }) {
            result.append(MeetingParticipant(name: attendee, spoke: false))
        }
        return result
    }
}
