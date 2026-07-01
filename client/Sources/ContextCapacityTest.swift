/// Tests the capacity limit of SpeechAnalyzer's contextualStrings
/// Usage: BetterVoice --test-context-capacity <wav-file>
#if BENCH
import AVFoundation
import Speech

enum ContextCapacityTest {
    @MainActor
    static func run() async {
        BetterVoiceDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--test-context-capacity"), idx + 1 < args.count else {
            print("Usage: BetterVoice --test-context-capacity <wav-file>")
            return
        }

        let wavPath = args[idx + 1]

        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        print("=== contextualStrings capacity test ===")
        print("Audio: \(wavPath)")
        print()

        // Test different counts of contextualStrings
        let testSizes = [0, 50, 100, 500, 1000, 5000]

        for size in testSizes {
            // Generate test vocabulary
            var words: [String] = []
            if size > 0 {
                // Mix real vocabulary with filler words
                let realWords = ["distillation", "fine-tuning", "Claude", "SpeechAnalyzer", "Whisper", "Gemini",
                                 "ollama", "data flywheel", "contextualStrings", "AlternativeSwap",
                                 "FluidAudio", "CoreML", "Tailscale", "MacOS", "speech recognition",
                                 "transcription", "polish", "correction", "model", "training"]
                words.append(contentsOf: realWords)
                for i in words.count..<size {
                    words.append("testword\(i)")
                }
            }

            print("--- \(size) words ---")

            do {
                let localeObj = Locale(identifier: "zh-CN")
                let transcriber = SpeechTranscriber(
                    locale: localeObj,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: [.audioTimeRange]
                )

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))

                // Inject contextualStrings
                if !words.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = words
                    try await analyzer.setContext(context)
                    print("  Injected: \(words.count) words ✓")
                } else {
                    print("  No context (baseline)")
                }

                // Collect the results
                let collector = AlternativesCollector()

                let resultTask = Task { @Sendable in
                    do {
                        for try await result in transcriber.results {
                            guard result.isFinal else { continue }
                            let text = String(result.text.characters)
                            await collector.add(best: text, alternatives: [], wordConfidences: [])
                        }
                    } catch {}
                }

                let start = CFAbsoluteTimeGetCurrent()
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                await resultTask.value
                let elapsed = CFAbsoluteTimeGetCurrent() - start

                let segments = await collector.segments
                let fullText = segments.map { $0.best }.joined()
                print("  Time: \(String(format: "%.2f", elapsed))s")
                print("  Segments: \(segments.count)")
                print("  Text: \(fullText.prefix(80))...")
                print()

            } catch {
                print("  ERROR: \(error)")
                print()
            }
        }
    }
}
#endif
