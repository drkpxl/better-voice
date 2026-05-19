@preconcurrency import AVFoundation
import CoreMedia
import Speech

/// 即时录音模式评估入口
/// 用法：
///   WE --bench-voice <wav> [--locale zh-CN] [--output result.json]
///   WE --bench-voice --batch <manifest.jsonl> [--output-dir results/]
///
/// 走完整 ContextEnhancer + SpeechAnalyzer + L2 polish 链路，输出 rawSA + finalText。
/// **不调用 TextInjector**（不注入光标），**不写 voice-history.jsonl**（不污染历史），
/// 这是与 VoiceSession 的唯一区别——其他链路完全等价。
///
/// 用于 KPI §3.2 L4 ①②③ 三项基线（短句准确率 / 中等 WER / 长句保留率），
/// 以"用户视角 + 全链路"为原则评估即时录音模式。
enum VoiceBenchmark {

    @MainActor
    static func run() async {
        WEDataDir.ensureExists()
        let args = CommandLine.arguments

        guard let benchIdx = args.firstIndex(of: "--bench-voice"), benchIdx + 1 < args.count else {
            print("Usage: WE --bench-voice <wav-file> [--locale zh-CN] [--output result.json]")
            print("       WE --bench-voice --batch <manifest.jsonl> [--output-dir results/]")
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
            // 1. 配置 SpeechTranscriber —— 与 VoiceSession 的核心配置一致
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

            // 2. 创建 SpeechAnalyzer
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            // 3. 上下文注入（字典 + OCR）—— 用户视角必须含此环节
            let polishCfg = RuntimeConfig.shared.polishConfig
            let dictEnabled = polishCfg["context_dictionary_enabled"] as? Bool ?? false
            let dictPath = polishCfg["context_dictionary_path"] as? String
            // bench 模式不做 OCR（屏幕焦点未知）
            let contextWords = await ContextEnhancer.enhance(
                for: nil,
                dictionaryEnabled: dictEnabled,
                dictionaryPath: dictPath,
                ocrEnabled: false
            )
            if !contextWords.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = contextWords
                try? await analyzer.setContext(ctx)
            }
            let tCtxDone = CFAbsoluteTimeGetCurrent()

            // 4. 结果收集
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

            // 5. 文件输入
            let inputFile = try AVAudioFile(forReading: fileURL)
            let audioDuration = Double(inputFile.length) / inputFile.processingFormat.sampleRate
            try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)
            await resultTask.value
            let tSADone = CFAbsoluteTimeGetCurrent()

            // 6. L2 polish（用户视角的最终文本）
            var polishedText: String? = nil
            let l2Enabled = polishCfg["enabled"] as? Bool ?? true
            if l2Enabled && !fullText.isEmpty {
                polishedText = await PolishClient.shared.polish(
                    text: fullText,
                    words: allWords,
                    app: nil
                )
            }
            let tL2Done = CFAbsoluteTimeGetCurrent()

            // 7. 输出
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
                "hypothesis": finalText,                  // 与 MeetingBenchmark 输出格式一致
                "context_terms": contextWords.count,
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

    // MARK: - 内部辅助

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
