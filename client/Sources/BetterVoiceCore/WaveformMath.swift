import Foundation

/// Pure amplitude + noise-floor math for the dictation waveform indicator.
public enum WaveformMath {

    /// Root-mean-square of an Int16 PCM buffer, normalized to 0...1.
    public static func rms(int16 samples: UnsafeBufferPointer<Int16>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Double = 0
        for s in samples {
            let v = Double(s) / 32768.0
            sumSquares += v * v
        }
        let mean = sumSquares / Double(samples.count)
        return Float(mean.squareRoot())
    }

    /// Array overload for ease of testing (avoids constructing an UnsafeBufferPointer in tests).
    public static func rms(int16 samples: [Int16]) -> Float {
        samples.withUnsafeBufferPointer { rms(int16: $0) }
    }
}
