#if BENCH
import AVFoundation
import BetterVoiceCore

/// Offline dictation-path check (BENCH builds only): runs a recording through Parakeet, with and
/// without vocabulary boosting, so engine-side changes can be compared without a microphone.
///
/// Usage:
///   BetterVoice2 --bench-dictation <audio-file> [--pad 1.5] [--locale de] [--boost "Term,Other Term"]
///
/// `--pad` surrounds the audio with that many seconds of near-silence (a quiet noise floor, like a
/// real room).
enum DictationBenchmark {
    @MainActor
    static func run() async {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--bench-dictation"), idx + 1 < args.count else {
            print("Usage: BetterVoice2 --bench-dictation <audio-file> [--pad 1.5] [--locale de]")
            return
        }
        let url = URL(fileURLWithPath: args[idx + 1])
        let pad = value(args, "--pad").flatMap(Double.init) ?? 0
        let locale = value(args, "--locale").map { Locale(identifier: $0) }

        guard let loaded = load(url) else {
            print("Error: could not read \(url.path)")
            return
        }
        let buffer = pad > 0 ? padded(loaded, seconds: pad) : loaded
        let audio = CapturedAudio(buffer)
        print(String(format: "audio: %.2fs @ %.0f Hz (pad %.1fs)", audio.duration, buffer.format.sampleRate, pad))

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let full = try await ParakeetTranscriber.shared.transcribe(audio: audio, locale: locale)
            print(String(format: "full    (%4.0f ms): %@", (CFAbsoluteTimeGetCurrent() - t0) * 1000, full.text))

            if let list = value(args, "--boost") {
                let terms = VocabularyBoostTerms.build(
                    terms: list.split(separator: ",").map(String.init),
                    replacements: []
                )
                try await VocabularyBooster.shared.prepare()
                let t3 = CFAbsoluteTimeGetCurrent()
                let boosted = try await ParakeetTranscriber.shared.transcribe(audio: audio, locale: locale, boostTerms: terms)
                print(String(format: "boosted (%4.0f ms incl. ASR): %@", (CFAbsoluteTimeGetCurrent() - t3) * 1000, boosted.text))
            }
        } catch {
            print("Error: \(error)")
        }
    }

    private static func value(_ args: [String], _ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return buffer
    }

    private static func padded(_ buffer: AVAudioPCMBuffer, seconds: Double) -> AVAudioPCMBuffer {
        let padFrames = AVAudioFrameCount(seconds * buffer.format.sampleRate)
        let total = buffer.frameLength + 2 * padFrames
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: total),
              let src = buffer.floatChannelData, let dst = out.floatChannelData else { return buffer }
        out.frameLength = total
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(total) { dst[ch][i] = Float.random(in: -0.002...0.002) }
            dst[ch].advanced(by: Int(padFrames)).update(from: src[ch], count: Int(buffer.frameLength))
        }
        return out
    }
}
#endif
