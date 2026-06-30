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

    /// 把原始 RMS 映射成 0...1 的可视电平。
    /// - 在噪声地板及以下返回 0（指示器保持平直/静止）。
    /// - 其上按 (rms - floor)/(1 - floor) 线性映射并乘以灵敏度，最后夹到 0...1。
    public static func normalizedLevel(rms: Float, noiseFloor: Float, sensitivity: Float) -> Float {
        let floor = max(0, min(noiseFloor, 0.999))
        guard rms > floor else { return 0 }
        let span = 1 - floor
        let scaled = (rms - floor) / span * max(0, sensitivity)
        return min(1, max(0, scaled))
    }
}
