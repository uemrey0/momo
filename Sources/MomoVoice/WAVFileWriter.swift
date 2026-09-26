import Foundation

/// Writes a long mono recording to a 16-bit WAV file as it arrives, so it never has to be
/// held in memory. The header's sizes are filled in by ``close()``.
///
/// Only used when the user asked Momo to keep meeting audio; by default meeting audio never
/// touches the disk.
public final class WAVFileWriter: @unchecked Sendable {
    public let url: URL
    private let sampleRate: Int
    private let handle: FileHandle
    private let lock = NSLock()
    private var dataBytes = 0
    private var isClosed = false

    /// Creates (or replaces) the file at `url`.
    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The header for an empty file; close() rewrites it with the real sizes.
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
        try? handle.write(contentsOf: data)
        dataBytes += data.count
    }

    /// Finishes the file. Further samples are ignored.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        func uint32(_ value: Int) -> Data {
            withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
        }
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: uint32(36 + dataBytes))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: uint32(dataBytes))
        try? handle.close()
    }

    deinit {
        close()
    }
}
