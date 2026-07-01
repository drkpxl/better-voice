@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// Entry point for evaluating instant-recording mode
/// Usage:
///   BetterVoice --bench-voice <wav> [--locale zh-CN] [--output result.json]
///   BetterVoice --bench-voice --batch <manifest.jsonl> [--output-dir results/]
///
/// Runs the full SpeechAnalyzer + L2 polish pipeline, outputting rawSA + finalText.
/// **Does not call TextInjector** (no cursor injection), **does not write voice-history.jsonl** (keeps history clean) —
/// that is the only difference from VoiceSession; the rest of the pipeline is identical.
///
/// Used for the three KPI §3.2 L4 ①②③ baselines (short-sentence accuracy / medium WER / long-sentence retention rate),
/// evaluating instant-recording mode on the principle of "user perspective + full pipeline."
enum VoiceBenchmark {

    @MainActor
    static func run() async {
        BetterVoiceDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let benchIdx = args.firstIndex(of: "--bench-voice"), benchIdx + 1 < args.count else {
            print("Usage: BetterVoice --bench-voice <wav-file> [--locale zh-CN] [--output result.json]")
            print("       BetterVoice --bench-voice --batch <manifest.jsonl> [--output-dir results/]")
            return
        }

        let locale = parseArg(args, key: "--locale") ?? "zh-CN"

        if args.contains("--batch") {
            guard let manifest = parseArg(args, key: "--batch") else {
                print("Error: --batch requires manifest file path")
                return
            }
            let outputDir = parseArg(args, key: "--output-dir") ?? "voice-bench-results"
            await runBatch(manifest: manifest, outputDir: outputDir, locale: locale)
        } else {
            let wavPath = args[benchIdx + 1]
            let output = parseArg(args, key: "--output")
            await runSingle(wavPath: wavPath, locale: locale, outputPath: output)
        }
    }

    @MainActor
    static func runSingle(wavPath: String, locale _: String, outputPath: String?) async {
        let fileURL = URL(fileURLWithPath: wavPath)
        guard FileManager.default.fileExists(atPath: wavPath) else {
            print("Error: file not found: \(wavPath)")
            return
        }

        let tStart = CFAbsoluteTimeGetCurrent()

        do {
            // 1. Configure SpeechTranscriber -- matches VoiceSession's core configuration
            guard let bestLocale = await SpeechUtils.findChineseLocale() else {
                print("Error: no Chinese locale available")
                return
            }

            let transcriber = SpeechTranscriber(
                locale: bestLocale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.transcriptionConfidence]
            )
            try await SpeechUtils.ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

            // 2. Create the SpeechAnalyzer
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            let tCtxDone = CFAbsoluteTimeGetCurrent()

            // 4. Result collection
            var fullText = ""
            var allWords: [WordInfo] = []
            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        if result.isFinal {
                            fullText += String(result.text.characters)
                            allWords.append(contentsOf: extractWords(from: result.text))
                        }
                    }
                } catch {
                    Logger.log("VoiceBench", "Stream error: \(error)")
                }
            }

            // 5. File input
            let inputFile = try AVAudioFile(forReading: fileURL)
            let audioDuration = Double(inputFile.length) / inputFile.processingFormat.sampleRate
            try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)
            await resultTask.value
            let tSADone = CFAbsoluteTimeGetCurrent()

            // 6. L2 polish (the final text from the user's perspective)
            var polishedText: String? = nil
            let polishCfg = RuntimeConfig.shared.polishConfig
            let l2Enabled = polishCfg["enabled"] as? Bool ?? true
            if l2Enabled && !fullText.isEmpty {
                polishedText = await PolishClient.shared.polish(
                    text: fullText,
                    words: allWords,
                    app: nil
                )
            }
            let tL2Done = CFAbsoluteTimeGetCurrent()

            // 7. Output
            let finalText = polishedText ?? fullText
            let totalMs = Int((tL2Done - tStart) * 1000)

            let result: [String: Any] = [
                "audio": wavPath,
                "duration_s": round(audioDuration * 100) / 100,
                "ctx_ms": Int((tCtxDone - tStart) * 1000),
                "sa_ms": Int((tSADone - tCtxDone) * 1000),
                "l2_ms": Int((tL2Done - tSADone) * 1000),
                "total_ms": totalMs,
                "rawSA": fullText,
                "polishedText": polishedText ?? NSNull(),
                "finalText": finalText,
                "hypothesis": finalText,                  // matches MeetingBenchmark's output format
                "n_words": allWords.count,
            ]

            if let outputPath {
                let data = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try data.write(to: URL(fileURLWithPath: outputPath))
                print("Result: \(outputPath)")
            } else {
                let data = try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted)
                print(String(data: data, encoding: .utf8) ?? "{}")
            }

            Logger.log(
                "VoiceBench",
                "audio=\(String(format: "%.1f", audioDuration))s ctx=\(Int((tCtxDone - tStart) * 1000))ms sa=\(Int((tSADone - tCtxDone) * 1000))ms l2=\(Int((tL2Done - tSADone) * 1000))ms total=\(totalMs)ms"
            )

        } catch {
            print("Error: \(error)")
        }
    }

    @MainActor
    static func runBatch(manifest manifestPath: String, outputDir: String, locale: String) async {
        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            print("Error: manifest not found: \(manifestPath)")
            return
        }
        let baseDir = manifestURL.deletingLastPathComponent()

        let outDir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: manifestURL),
              let raw = String(data: data, encoding: .utf8) else {
            print("Error: cannot read manifest")
            return
        }

        let lines = raw.split(separator: "\n").map(String.init)
        print("Batch: \(lines.count) entries")

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? String,
                  let audio = obj["audio"] as? String
            else {
                print("[\(idx + 1)/\(lines.count)] skip invalid line")
                continue
            }

            let audioPath = baseDir.appendingPathComponent(audio).path
            let outPath = outDir.appendingPathComponent("\(id).json").path
            print("[\(idx + 1)/\(lines.count)] \(id) ...")
            await runSingle(wavPath: audioPath, locale: locale, outputPath: outPath)
        }
        print("Batch done: \(outDir.path)")
    }

    // MARK: - Internal helpers

    private static func extractWords(from attrText: AttributedString) -> [WordInfo] {
        var words: [WordInfo] = []
        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        for (confidence, range) in attrText.runs[ConfKey.self] {
            let wordText = String(attrText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            words.append(WordInfo(
                text: wordText,
                confidence: Float(confidence ?? 1.0),
                alternatives: [],
                startTime: 0,
                duration: 0
            ))
        }
        return words
    }

    private static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
