/// A stretch of speech in a recording, in seconds from its start.
public struct SpeechStretch: Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Groups the speech a voice activity detector found in a recording into the stretches that
/// are transcribed one by one.
public enum SpeechStretches {
    /// Joins stretches separated by less than `gap` seconds, so a sentence with a short
    /// pause is transcribed as one, unless the joined stretch would be longer than
    /// `longest` seconds.
    ///
    /// - Parameter stretches: Speech in any order; empty or reversed stretches are dropped.
    /// - Returns: The joined stretches, in order.
    public static func merge(
        _ stretches: [SpeechStretch], gap: Double = 0.6, longest: Double = 30
    ) -> [SpeechStretch] {
        let sorted = stretches.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var merged: [SpeechStretch] = []
        for stretch in sorted {
            if var last = merged.last, stretch.start - last.end < gap,
                max(last.end, stretch.end) - last.start <= longest
            {
                last.end = max(last.end, stretch.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(stretch)
            }
        }
        return merged
    }
}
