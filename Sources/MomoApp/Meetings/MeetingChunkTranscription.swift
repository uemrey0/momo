import Foundation
import MomoKit
import MomoVoice

/// What became of one chunk of a meeting.
enum ChunkTranscription {
    /// The meeting's own speech engine transcribed it.
    case transcribed(Transcript)
    /// Momo's voice models transcribed it instead of the cloud service: after `cloudError`,
    /// or without asking the cloud at all while it is paused (`cloudError` is `nil`).
    case fellBack(Transcript, cloudError: (any Error)?)
    /// Nothing could transcribe it; the transcript has a gap here.
    case lost(any Error)
    /// The meeting stopped while it was being transcribed.
    case cancelled

    var transcript: Transcript? {
        switch self {
        case .transcribed(let transcript), .fellBack(let transcript, _): transcript
        case .lost, .cancelled: nil
        }
    }

    /// What to tell the user about it, if anything.
    var notice: String? {
        switch self {
        case .transcribed, .cancelled, .fellBack(_, cloudError: nil):
            nil
        case .fellBack(_, let cloudError?):
            String(
                format: L(
                    "Cloud transcription failed for part of the meeting, so Momo transcribed it on this Mac. %@"
                ), cloudError.localizedDescription)
        case .lost(let error):
            String(
                format: L("Part of the meeting couldn't be transcribed. %@"),
                error.localizedDescription)
        }
    }

    /// Where a chunk is sent.
    enum Route: Equatable {
        /// The meeting's speech engine (the cloud service, or the Mac for on-device meetings).
        case engine
        /// Straight to the engine's fallback on this Mac.
        case fallback
    }

    /// Transcribes `clip` along `route`, falling back to the Mac when a cloud request fails.
    static func transcribe(
        _ clip: AudioClip, engine: MeetingController.TranscriptionEngine,
        options: TranscriptionOptions, route: Route
    ) async -> ChunkTranscription {
        let fallbackOptions = TranscriptionOptions(wantsSegments: true)
        if route == .fallback, let fallback = engine.fallback {
            return await transcribe(clip, with: fallback, options: fallbackOptions) {
                .fellBack($0, cloudError: nil)
            }
        }
        do {
            return .transcribed(try await engine.service.transcribe(clip, options: options))
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            guard engine.isRemote, let fallback = engine.fallback else { return .lost(error) }
            return await transcribe(clip, with: fallback, options: fallbackOptions) {
                .fellBack($0, cloudError: error)
            }
        }
    }

    private static func transcribe(
        _ clip: AudioClip, with service: any AudioTranscriptionService,
        options: TranscriptionOptions, success: (Transcript) -> ChunkTranscription
    ) async -> ChunkTranscription {
        do {
            return success(try await service.transcribe(clip, options: options))
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            return .lost(error)
        }
    }
}

/// Keeps a stalled cloud service from building an endless backlog during a meeting: after a
/// cloud request fails, chunks go to the Mac for a while, and a track that has fallen behind
/// skips the cloud until it has caught up.
struct MeetingCloudBreaker {
    /// How many chunks a track may have waiting; older ones are dropped beyond this.
    static let maximumBacklog = 8
    /// From this many waiting chunks on, a track skips the cloud.
    static let catchUpBacklog = 3

    /// How long the cloud is left alone after a failure.
    var coolDown: TimeInterval = 120
    private(set) var pausedUntil: Date?

    /// Where the next chunk of a track with `backlog` chunks waiting should go.
    func route(
        for engine: MeetingController.TranscriptionEngine, backlog: Int, now: Date = Date()
    ) -> ChunkTranscription.Route {
        guard engine.isRemote, engine.fallback != nil else { return .engine }
        if backlog >= Self.catchUpBacklog { return .fallback }
        if let pausedUntil, now < pausedUntil { return .fallback }
        return .engine
    }

    /// Notes how a chunk sent to the cloud fared.
    mutating func record(_ result: ChunkTranscription, now: Date = Date()) {
        switch result {
        case .transcribed: pausedUntil = nil
        case .fellBack, .lost: pausedUntil = now.addingTimeInterval(coolDown)
        case .cancelled: break
        }
    }
}

/// Spaces out saves of the meeting being recorded: every save rewrites the whole store, so
/// new transcript is saved at most once per `interval`, and status changes right away.
struct MeetingSaveSchedule {
    var interval: TimeInterval = 30
    private(set) var lastSave: Date?

    /// How long to wait before saving a change made at `now`; zero to save now.
    func delay(now: Date = Date()) -> TimeInterval {
        guard let lastSave else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastSave))
    }

    mutating func saved(at date: Date = Date()) {
        lastSave = date
    }
}

/// Recovers the audio files of a meeting that was interrupted, for example by a crash.
enum MeetingAudioRecovery {
    /// Repairs the headers of the WAV files in the meeting's folder and returns their paths
    /// relative to `meetingsDirectory`, as ``Meeting/audioFiles`` names them.
    static func recover(meetingID: String, in meetingsDirectory: URL) -> [String] {
        let folder = meetingsDirectory.appendingPathComponent(meetingID, isDirectory: true)
        return MeetingTrack.allCases.compactMap { track in
            let name = "\(track.rawValue).wav"
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                WAVFileWriter.repairHeader(at: url)
            else { return nil }
            return "\(meetingID)/\(name)"
        }
    }
}
