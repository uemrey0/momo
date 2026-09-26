import Foundation

/// Encodes and decodes the plain audio formats the cloud services use.
public enum WAVEncoder {
    /// Encodes mono samples from -1 to 1 as a 16-bit PCM WAV file.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        append(UInt32(16))  // size of the format chunk
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))  // byte rate
        append(UInt16(bytesPerSample))  // block align
        append(UInt16(16))  // bits per sample
        data.append(Data("data".utf8))
        append(UInt32(dataSize))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    /// Decodes a 16-bit PCM WAV file (as written by ``encode(samples:sampleRate:)``) into its
    /// samples and sample rate, mixing channels down to mono. Returns `nil` for anything else.
    public static func decode(_ data: Data) -> (samples: [Float], sampleRate: Int)? {
        let bytes = [UInt8](data)
        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
        }
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46],
            bytes[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { return nil }
        var offset = 12
        var channels = 1
        var sampleRate = 0
        var bitsPerSample = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = uint32(offset + 4)
            let body = offset + 8
            if id == "fmt ", body + 16 <= bytes.count {
                guard uint16(body) == 1 else { return nil }
                channels = max(1, uint16(body + 2))
                sampleRate = uint32(body + 4)
                bitsPerSample = uint16(body + 14)
            } else if id == "data" {
                guard bitsPerSample == 16, sampleRate > 0 else { return nil }
                let end = min(bytes.count, body + size)
                let mono = samples(fromPCM16: Data(bytes[body..<end]))
                guard channels > 1 else { return (mono, sampleRate) }
                let frames = mono.count / channels
                let mixed = (0..<frames).map { frame in
                    (0..<channels).reduce(Float(0)) { $0 + mono[frame * channels + $1] }
                        / Float(channels)
                }
                return (mixed, sampleRate)
            }
            offset = body + size + size % 2
        }
        return nil
    }

    /// Decodes raw 16-bit little-endian PCM (OpenAI's `pcm` speech format) into samples from
    /// -1 to 1. A trailing odd byte is ignored.
    public static func samples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let value = Int16(bitPattern: low | (high << 8))
                samples[index] = Float(value) / Float(Int16.max)
            }
        }
        return samples
    }
}
