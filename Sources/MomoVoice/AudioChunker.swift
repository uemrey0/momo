import Foundation

/// Cuts a long recording into chunks for transcription, one chunk at a time, keeping only the
/// audio that has not been handed out yet in memory.
///
/// A chunk ends at the quietest moment between ``Configuration/minimumDuration`` and
/// ``Configuration/maximumDuration``, so words are rarely cut in half and chunks need no
/// overlap (which would transcribe the same words twice). Each chunk knows when it started,
/// so its transcript can be moved into place with ``Transcript/offset(by:)``.
///
/// ```swift
/// var chunker = AudioChunker()
/// for chunk in chunker.append(samples) { transcribe(chunk) }
/// if let last = chunker.finish() { transcribe(last) }
/// ```
public struct AudioChunker: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var sampleRate: Int
        /// The shortest chunk, unless the recording ends sooner.
        public var minimumDuration: TimeInterval
        /// The longest chunk; one is cut here when there is no quiet moment before.
        public var maximumDuration: TimeInterval
        /// The window whose loudness is compared when looking for a quiet moment.
        public var frameDuration: TimeInterval

        public init(
            sampleRate: Int = 16_000, minimumDuration: TimeInterval = 20,
            maximumDuration: TimeInterval = 30, frameDuration: TimeInterval = 0.1
        ) {
            self.sampleRate = sampleRate
            self.minimumDuration = min(minimumDuration, maximumDuration)
            self.maximumDuration = maximumDuration
            self.frameDuration = frameDuration
        }
    }

    /// A piece of the recording.
    public struct Chunk: Sendable, Equatable {
        /// Counts from 0.
        public var index: Int
        /// Seconds from the start of the recording.
        public var start: TimeInterval
        /// Mono samples from -1 to 1.
        public var samples: [Float]
        public var sampleRate: Int

        public var duration: TimeInterval { Double(samples.count) / Double(max(1, sampleRate)) }
    }

    public let configuration: Configuration
    private var buffer: [Float] = []
    private var consumed = 0
    private var nextIndex = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Seconds of audio waiting for the next chunk.
    public var pendingDuration: TimeInterval {
        Double(buffer.count) / Double(configuration.sampleRate)
    }

    /// Adds recorded samples and returns the chunks that are complete.
    public mutating func append(_ samples: [Float]) -> [Chunk] {
        buffer.append(contentsOf: samples)
        let maximum = Int(configuration.maximumDuration * Double(configuration.sampleRate))
        let minimum = Int(configuration.minimumDuration * Double(configuration.sampleRate))
        let frame = max(1, Int(configuration.frameDuration * Double(configuration.sampleRate)))
        var chunks: [Chunk] = []
        while buffer.count >= maximum {
            let cut = Self.quietestCut(in: buffer, from: minimum, to: maximum, frame: frame)
            chunks.append(take(cut))
        }
        return chunks
    }

    /// Returns what is left as a last chunk, or `nil` when nothing is left.
    public mutating func finish() -> Chunk? {
        guard !buffer.isEmpty else { return nil }
        return take(buffer.count)
    }

    private mutating func take(_ count: Int) -> Chunk {
        let chunk = Chunk(
            index: nextIndex, start: Double(consumed) / Double(configuration.sampleRate),
            samples: Array(buffer[..<count]), sampleRate: configuration.sampleRate)
        buffer.removeFirst(count)
        consumed += count
        nextIndex += 1
        return chunk
    }

    /// Where to cut `samples` between `lower` and `upper`: the start of the quietest frame,
    /// the latest one on a tie. Returns `upper` when the range is empty.
    static func quietestCut(in samples: [Float], from lower: Int, to upper: Int, frame: Int) -> Int
    {
        let upper = min(upper, samples.count)
        guard lower < upper - frame else { return max(1, upper) }
        var best = upper
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = lower
        while position + frame <= upper {
            var energy: Float = 0
            for index in position..<(position + frame) { energy += samples[index] * samples[index] }
            if energy <= bestEnergy {
                bestEnergy = energy
                best = position + frame / 2
            }
            position += frame
        }
        return max(1, best)
    }

    /// Whether `samples` hold enough sound to be worth transcribing: at least
    /// `minimumActive` seconds of frames louder than `threshold` (RMS, about -40 dB by
    /// default). Silent chunks are skipped, which saves time and keeps silence off the
    /// network.
    public static func hasSound(
        _ samples: [Float], sampleRate: Int, threshold: Float = 0.01,
        minimumActive: TimeInterval = 0.3, frameDuration: TimeInterval = 0.05
    ) -> Bool {
        let frame = max(1, Int(frameDuration * Double(sampleRate)))
        let needed = max(1, Int((minimumActive / frameDuration).rounded(.up)))
        var active = 0
        var position = 0
        while position + frame <= samples.count {
            var sum: Float = 0
            for index in position..<(position + frame) { sum += samples[index] * samples[index] }
            if (sum / Float(frame)).squareRoot() > threshold {
                active += 1
                if active >= needed { return true }
            }
            position += frame
        }
        return false
    }
}

extension Transcript {
    /// The segments of one chunk of a longer recording, moved to the chunk's start and with
    /// speaker labels scoped to the chunk: speaker "A" of the chunk with index 2 becomes "3A".
    ///
    /// Transcription services label speakers per request, so the same person usually gets a
    /// different label in the next chunk; scoping the labels keeps them from being confused,
    /// and a later step can match labels to names.
    public func chunkSegments(index: Int, start: TimeInterval) -> [TranscriptSegment] {
        let letters = SpeakerLabels(segments.compactMap(\.speaker))
        return offset(by: start).segments.map { segment in
            var scoped = segment
            scoped.speaker = segment.speaker.map { "\(index + 1)\(letters.letter(for: $0))" }
            return scoped
        }
    }
}

/// Turns a service's speaker labels ("A", "speaker_0", "1", "Speaker B") into letters A, B,
/// C… in the order speakers first appear.
struct SpeakerLabels {
    private var letters: [String: String] = [:]

    init(_ labels: [String]) {
        var order: [String] = []
        for label in labels {
            let key = Self.key(label)
            if !order.contains(key) { order.append(key) }
        }
        // Services that already use letters keep them; anything else is lettered by order.
        let alreadyLetters = order.allSatisfy { $0.count == 1 && $0.first?.isLetter == true }
        for (position, key) in order.enumerated() {
            letters[key] = alreadyLetters ? key : Self.letter(at: position)
        }
    }

    func letter(for label: String) -> String {
        letters[Self.key(label)] ?? Self.key(label)
    }

    private static func key(_ label: String) -> String {
        var text = label.trimmingCharacters(in: .whitespaces).uppercased()
        for prefix in ["SPEAKER_", "SPEAKER ", "SPEAKER"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            break
        }
        return text.isEmpty ? "?" : text
    }

    /// A, B, … Z, then AA, AB…
    static func letter(at position: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return position < alphabet.count
            ? String(alphabet[position])
            : letter(at: position / alphabet.count - 1)
                + String(alphabet[position % alphabet.count])
    }
}
