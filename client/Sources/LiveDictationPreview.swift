import AVFoundation
import BetterVoiceCore

/// Live transcript shown under the recording HUD while you talk.
///
/// Re-transcribes the recording's trailing window with the same Parakeet engine every
/// `interval`, rather than running a separate streaming model. Parakeet is fast enough that this
/// is the cheap option — about 0.004 s per second of audio, so a 12 s window costs ~50 ms — and it
/// means the preview needs no second download and shows exactly what the engine hears. FluidAudio's
/// sliding-window streamer was the obvious alternative and is no use here: it emits nothing until
/// it has a full 11 s chunk plus 2 s of look-ahead, which is longer than most dictations.
///
/// Display only. The inserted text still comes from one pass over the whole recording on stop
/// (`VoiceModule.stopAndProcess`), so the preview can never cost accuracy.
@MainActor
final class LiveDictationPreview {
    /// Newest preview text (vocabulary + filler pass applied, like the final text).
    var onText: ((String) -> Void)?

    /// How far back the preview reads. The panel shows the last couple of lines, so older audio
    /// would only be transcribed to be truncated away.
    private static let window: TimeInterval = 12
    private static let interval: Duration = .milliseconds(600)
    /// Below this there is nothing worth showing yet.
    private static let minimumSeconds: TimeInterval = 0.6

    private var loop: Task<Void, Never>?

    /// Start previewing `recorder`. Replaces any previous run.
    func start(recorder: DictationRecorder) {
        stop()
        guard RuntimeConfig.shared.livePreviewEnabled else { return }
        loop = Task { [weak self] in
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                // Skip when nothing new arrived (capture stalled). Counted in buffers captured, not
                // the tail's length — past the window the tail is always the same length.
                let count = recorder.capturedBufferCount
                guard !Task.isCancelled, count != lastCount,
                      let buffer = recorder.snapshotTail(maxSeconds: Self.window) else { continue }
                let audio = CapturedAudio(buffer)
                guard audio.duration >= Self.minimumSeconds else { continue }
                lastCount = count
                do {
                    let transcript = try await ParakeetTranscriber.shared.transcribe(audio: audio, locale: RuntimeConfig.shared.speechLocale)
                    guard !Task.isCancelled else { return }
                    let text = Self.display(transcript.text)
                    if !text.isEmpty { self?.onText?(text) }
                } catch {
                    // A preview failure is cosmetic; the final pass reports real errors.
                    Logger.log("Preview", "Preview transcription failed: \(error)")
                }
            }
        }
    }

    /// The last stopped run, kept so `stopAndWait()` can still wait for it after a plain `stop()`.
    private var stopping: Task<Void, Never>?

    func stop() {
        if let loop { stopping = loop }
        loop?.cancel()
        loop = nil
    }

    /// Stop, and wait for a pass already inside the engine to finish.
    func stopAndWait() async {
        stop()
        let running = stopping
        stopping = nil
        await running?.value
    }

    private static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = RuntimeConfig.shared.fillerStrippingActive ? FillerStripper.strip(trimmed).text : trimmed
        return Vocabulary.shared.apply(to: stripped)
    }
}
