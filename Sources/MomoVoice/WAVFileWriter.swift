import Foundation

/// Writes a long mono recording to a 16-bit WAV file as it arrives, so it never has to be
/// held in memory. The header's sizes are brought up to date every few seconds of audio and
/// by ``close()``, so a file cut short by a crash is still readable (and
/// ``repairHeader(at:)`` fixes whatever the last update missed).
///
/// Only used when the user asked Momo to keep meeting audio; by default meeting audio never
/// touches the disk.
public final class WAVFileWriter: @unchecked Sendable {
    /// The size of the header ``WAVEncoder`` writes, before the samples.
    static let headerBytes = 44

    public let url: URL
    private let sampleRate: Int
    private let handle: FileHandle
    private let lock = NSLock()
    private let headerUpdateBytes: Int
    private var dataBytes = 0
    private var headerDataBytes = 0
    private var isClosed = false

    /// Creates (or replaces) the file at `url`. The header's sizes are rewritten after every
    /// `headerUpdateInterval` seconds of audio.
    public init(url: URL, sampleRate: Int, headerUpdateInterval: TimeInterval = 5) throws {
        self.url = url
        self.sampleRate = sampleRate
        headerUpdateBytes = max(2, Int(headerUpdateInterval * Double(sampleRate)) * 2)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The header for an empty file; it is rewritten with the real sizes as audio arrives.
        try WAVEncoder.encode(samples: [], sampleRate: sampleRate).write(to: url)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// Appends samples from -1 to 1.
    public func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        guard (try? handle.write(contentsOf: data)) != nil else { return }
        dataBytes += data.count
        if dataBytes - headerDataBytes >= headerUpdateBytes {
            writeSizes()
            _ = try? handle.seekToEnd()
        }
    }

    /// Finishes the file. Further samples are ignored.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        writeSizes()
        try? handle.close()
    }

    /// Writes the current sizes into the header. Call with the lock held; leaves the file
    /// position inside the header.
    private func writeSizes() {
        Self.writeSizes(dataBytes: dataBytes, to: handle)
        headerDataBytes = dataBytes
    }

    private static func writeSizes(dataBytes: Int, to handle: FileHandle) {
        func uint32(_ value: Int) -> Data {
            withUnsafeBytes(of: UInt32(clamping: value).littleEndian) { Data($0) }
        }
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: uint32(headerBytes - 8 + dataBytes))
        try? handle.seek(toOffset: UInt64(headerBytes - 4))
        try? handle.write(contentsOf: uint32(dataBytes))
    }

    /// Sets the header's sizes of a WAV file written by this class from the file's length,
    /// for a file whose recording was cut short before ``close()``. Returns whether the file
    /// looked like one of ours and was repaired.
    @discardableResult
    public static func repairHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        let header = [UInt8]((try? handle.read(upToCount: headerBytes)) ?? Data())
        guard header.count == headerBytes, Array(header[0..<4]) == Array("RIFF".utf8),
            Array(header[8..<12]) == Array("WAVE".utf8),
            Array(header[36..<40]) == Array("data".utf8),
            let length = try? handle.seekToEnd()
        else { return false }
        let samples = (Int(length) - headerBytes) / 2
        writeSizes(dataBytes: samples * 2, to: handle)
        return true
    }

    deinit {
        close()
    }
}
