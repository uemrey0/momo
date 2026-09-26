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
