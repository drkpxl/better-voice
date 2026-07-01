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

/// Owns a lazily-built `AVAudioConverter` and rebuilds it whenever the input format changes
/// (e.g. a mid-session device switch: AirPods Int16 → built-in Float32). Replaces the
/// lazy-converter-keyed-to-first-buffer pattern that silently broke on a format change.
///
/// Not an actor: instances are cheap value holders meant to be created per capture delegate
/// and touched only from that delegate's capture queue, same single-queue contract as before.
final class FormatConverter {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }

        if converter == nil || buffer.format != inputFormat {
            converter = AVAudioConverter(from: buffer.format, to: target)
            inputFormat = buffer.format
            Logger.log("Audio", "Rebuilt converter: \(buffer.format) → \(target)")
        }

        guard let converter else { return nil }
        return convertPCM(buffer: buffer, using: converter, to: target)
    }
}
