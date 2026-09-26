import Foundation

/// Loudness helpers for the `level` and `mouth` events.
public enum AudioLevel {
    /// The root mean square of samples.
    public static func rms(_ samples: some Collection<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS value to 0...1 on a decibel scale, so quiet speech still moves the meter:
    /// -55 dBFS and below is 0, -5 dBFS and above is 1.
    public static func normalized(rms: Float) -> Double {
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(Double(rms))
        return min(1, max(0, (decibels + 55) / 50))
    }
}
