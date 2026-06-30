import AVFoundation
import Speech

/// Tests what SpeechAnalyzer's alternativeTranscriptions returns
/// Usage: BetterVoice --test-alternatives <wav-file> [--locale zh-CN]
enum AlternativesTest {
    @MainActor
    static func run() async {
        BetterVoiceDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--test-alternatives"), idx + 1 < args.count else {
            print("Usage: BetterVoice --test-alternatives <wav-file> [--locale zh-CN]")
            return
        }

        let wavPath = args[idx + 1]
        let locale = MeetingBenchmark.parseArg(args, key: "--locale") ?? "zh-CN"

        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        print("=== SpeechAnalyzer alternatives test ===")
        print("Audio: \(wavPath)")
        print("Locale: \(locale)")
        print()

        do {
            let localeObj = Locale(identifier: locale)

            // Configure SpeechTranscriber, requesting alternatives
            let transcriber = SpeechTranscriber(
                locale: localeObj,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )

            // Ensure the model is installed
            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.language.languageCode == localeObj.language.languageCode }) {
                print("Downloading speech model...")
                if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await downloader.downloadAndInstall()
                }
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))

            // Collect the results
            let collector = AlternativesCollector()

            let resultTask = Task { @Sendable in
                do {
                    for try await result in transcriber.results {
                        guard result.isFinal else { continue }

                        let bestText = String(result.text.characters)

                        // Extract word-level confidence
                        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
                        var wordConfs: [(String, Double)] = []
                        for (confidence, range) in result.text.runs[ConfKey.self] {
                            let word = String(result.text[range].characters)
                            let trimmed = word.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                wordConfs.append((trimmed, confidence ?? 1.0))
                            }
                        }

                        // Collect the alternatives text
                        var altTexts: [String] = []
                        for alt in result.alternatives {
                            altTexts.append(String(alt.characters))
                        }

                        await collector.add(
                            best: bestText,
                            alternatives: altTexts,
                            wordConfidences: wordConfs
                        )
                    }
                } catch {
                    print("Stream error: \(error)")
                }
            }

            // Feed the audio
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            await resultTask.value

            // Print the results
            let segments = await collector.segments
            print("\n=== Results: \(segments.count) final segments ===\n")

            for (i, seg) in segments.enumerated() {
                print("--- Segment \(i + 1) ---")
                print("Best:         \(seg.best)")
                print("Alternatives: \(seg.alternatives.count)")

                if seg.alternatives.count > 1 {
                    for (j, alt) in seg.alternatives.enumerated() {
                        if alt != seg.best {
                            print("  alt[\(j)]:    \(alt)")
                        }
                    }
                } else {
                    print("  (no additional candidates)")
                }

                // Low-confidence words
                let lowConf = seg.wordConfidences.filter { $0.1 < 0.8 }
                if !lowConf.isEmpty {
                    print("Low confidence words:")
                    for (word, conf) in lowConf {
                        print("  \"\(word)\" → \(String(format: "%.2f", conf))")
                    }
                }
                print()
            }

            // Statistics
            let totalAlts = segments.reduce(0) { $0 + $1.alternatives.count }
            let hasMultiple = segments.filter { $0.alternatives.count > 1 }.count
            print("=== Statistics ===")
            print("Total segments: \(segments.count)")
            print("Total alternatives across all segments: \(totalAlts)")
            print("Segments with >1 alternative: \(hasMultiple)")
            print("Average alternatives per segment: \(segments.isEmpty ? 0 : Double(totalAlts) / Double(segments.count))")

        } catch {
            print("Error: \(error)")
        }
    }
}

actor AlternativesCollector {
    struct Segment {
        let best: String
        let alternatives: [String]
        let wordConfidences: [(String, Double)]
    }

    var segments: [Segment] = []

    func add(best: String, alternatives: [String], wordConfidences: [(String, Double)]) {
        segments.append(Segment(best: best, alternatives: alternatives, wordConfidences: wordConfidences))
    }
}
