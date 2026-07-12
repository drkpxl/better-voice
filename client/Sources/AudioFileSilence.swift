@preconcurrency import AVFoundation
import BetterVoiceCore

/// Reads a just-finalized meeting WAV and decides whether it's effectively empty/silent (Bug 2):
/// `MeetingCoordinator.stopMeeting()` calls this BEFORE handing the recording off to
/// `ImportPipeline`, which would otherwise surface a confusing raw transcription error instead of
/// a clear "nothing was captured, check your permissions" message.
///
/// Reads in bounded-memory chunks via `AVAudioFile` (same read pattern `ImportPipeline.run`
/// already uses to probe an imported file) rather than loading a whole — potentially hours-long —
/// recording into memory; `RunningRMS` (Core) accumulates one overall RMS across every chunk.
/// Synchronous/blocking I/O — callers should run this off the main actor (`stopMeeting()` uses
/// `Task.detached`).
func isRecordingEffectivelyEmpty(at url: URL) -> Bool {
    guard let file = try? AVAudioFile(forReading: url) else {
        Logger.log("Meeting", "Empty-recording check: couldn't open \(url.lastPathComponent)")
        return true
    }
    guard file.length > 0 else { return true }

    var running = RunningRMS()
    let chunkFrames: AVAudioFrameCount = 48000  // ~1s at a typical meeting-recording sample rate
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
        return true
    }

    while file.framePosition < file.length {
        do {
            try file.read(into: buffer)
        } catch {
            Logger.log("Meeting", "Empty-recording check: read error at \(file.framePosition)/\(file.length): \(error)")
            break
        }
        guard buffer.frameLength > 0 else { break }
        running.add(silenceCheckSamples(of: buffer))
    }

    let silent = AudioSilenceCheck.isEffectivelySilent(frameCount: Int(file.length), rms: running.rms)
    Logger.log("Meeting", "Empty-recording check: frames=\(file.length) rms=\(running.rms) silent=\(silent)")
    return silent
}

/// Channel-0 samples of a buffer, normalized to Float regardless of the underlying PCM format
/// (`AVAudioFile.processingFormat` is typically Float32, but this doesn't assume that).
private func silenceCheckSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return [] }
    if let floatData = buffer.floatChannelData {
        return Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
    }
    if let intData = buffer.int16ChannelData {
        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { out[i] = Float(intData[0][i]) / 32768.0 }
        return out
    }
    if let int32Data = buffer.int32ChannelData {
        var out = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount { out[i] = Float(int32Data[0][i]) / 2147483648.0 }
        return out
    }
    return []
}
