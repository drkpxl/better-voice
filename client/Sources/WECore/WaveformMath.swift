import Foundation

/// 波形/电平计算（纯函数，可单测）。
/// Pure amplitude + noise-floor math for the dictation waveform indicator.
public enum WaveformMath {

    /// 计算 Int16 PCM 缓冲的归一化 RMS（0...1）。
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

    /// 数组重载，便于测试（避免在测试里构造 UnsafeBufferPointer）。
    public static func rms(int16 samples: [Int16]) -> Float {
        samples.withUnsafeBufferPointer { rms(int16: $0) }
    }
}
