@preconcurrency import AVFoundation

/// One-shot resample/reformat of a single PCM buffer using a pre-built `AVAudioConverter`.
///
/// Extracted from `SystemAudioCapturer` and `MeetingCaptureDelegate`, which held identical
/// copies. The `Box` flag ensures the source buffer is handed to the converter exactly once
/// (subsequent pulls report `.noDataNow`), producing one output buffer per input buffer.
func convertPCM(buffer: AVAudioPCMBuffer,
                using converter: AVAudioConverter,
                to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

    var error: NSError?
    let consumed = Box(false)
    converter.convert(to: output, error: &error) { _, outStatus in
        if consumed.value {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed.value = true
        outStatus.pointee = .haveData
        return buffer
    }

    return (error == nil && output.frameLength > 0) ? output : nil
}
