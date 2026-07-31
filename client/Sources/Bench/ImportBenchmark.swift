import Foundation
import BetterVoiceCore

#if BENCH
/// Offline import-pipeline evaluation CLI (permanent dev tool, BENCH builds only).
///
/// Runs the file-import engine (`ImportPipeline`) against an audio file and prints a JSON result
/// dict — no UI, no live capture, no writes to Apple Notes.
///
/// Usage:
///   BetterVoice2 --bench-meeting <audio-file> [--locale zh-CN] [--single]
///                [--workspace <dir>] [--output result.json]
///   BetterVoice2 --bench-meeting --batch <manifest.jsonl> [--output-dir results/]
///                [--locale zh-CN] [--single] [--workspace <dir>]
///
/// The manifest is JSONL, one `{"audio": "...", "id": "...", "locale": "..."}` object per line
/// (`id`/`locale` optional). An optional `<audio-file>.speakers.json` diarization ground-truth
/// sidecar next to the audio adds DER-proxy scores to the output.
enum ImportBenchmark {
    @MainActor
    static func run() async {
        let args = CommandLine.arguments

        guard let benchIdx = args.firstIndex(of: "--bench-meeting"), benchIdx + 1 < args.count else {
            print("Usage: BetterVoice2 --bench-meeting <audio-file> [--locale zh-CN] [--single] [--workspace <dir>] [--output result.json]")
            print("       BetterVoice2 --bench-meeting --batch <manifest.jsonl> [--output-dir results/] [--locale zh-CN] [--single] [--workspace <dir>]")
            return
        }

        // Configure an isolated bench support dir (never touches the real Application Support path).
        let workspaceDir = parseArg(args, key: "--workspace")
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("bettervoice2-bench")
        let workspaceURL = URL(fileURLWithPath: workspaceDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        SupportDir.configure(root: workspaceURL)

        let locale = parseArg(args, key: "--locale")
        let single = args.contains("--single")

        if args.contains("--batch") {
            guard let manifest = parseArg(args, key: "--batch") else {
                print("Error: --batch requires manifest file path")
                return
            }
            let outputDir = parseArg(args, key: "--output-dir") ?? "bench-results"
            await runBatch(manifest: manifest, outputDir: outputDir, locale: locale, single: single)
        } else {
            let audioPath = args[benchIdx + 1]
            let output = parseArg(args, key: "--output")
            await runSingle(audioPath: audioPath, locale: locale, single: single, outputPath: output)
        }
    }

    @MainActor
    static func runSingle(audioPath: String, locale: String?, single: Bool, outputPath: String?) async {
        let fileURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            print("Error: file not found: \(audioPath)")
            return
        }

        print("Audio: \(audioPath)")
        print("Locale: \(locale ?? "(auto)")")
        print("Mode: \(single ? "single" : "multi")")

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await ImportPipeline().run(
                fileURL,
                speakerMode: single ? .single : .multi,
                locale: locale
            )
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            let json = formatResult(result, totalTime: totalTime)

            if let outputPath {
                let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                try? data?.write(to: URL(fileURLWithPath: outputPath))
                print("Result: \(outputPath)")
            } else {
                let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
            }
        } catch {
            print("Error: import failed: \(error)")
        }
    }

    @MainActor
    static func runBatch(manifest: String, outputDir: String, locale: String?, single: Bool) async {
        guard let content = try? String(contentsOfFile: manifest, encoding: .utf8) else {
            print("Error: cannot read \(manifest)")
            return
        }

        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        print("Manifest: \(manifest) (\(lines.count) files)")
        print("Output: \(outputDir)/\n")

        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioPath = entry["audio"] as? String else {
                print("[\(i+1)/\(lines.count)] SKIP: invalid line")
                continue
            }

            let id = entry["id"] as? String ?? URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
            let entryLocale = entry["locale"] as? String ?? locale

            print("[\(i+1)/\(lines.count)] \(id) ...", terminator: " ")
            fflush(stdout)

            let fileURL = URL(fileURLWithPath: audioPath)
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let result = try await ImportPipeline().run(
                    fileURL,
                    speakerMode: single ? .single : .multi,
                    locale: entryLocale
                )
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime

                let json = formatResult(result, totalTime: totalTime)
                let jsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                let outPath = "\(outputDir)/\(id).json"
                try? jsonData?.write(to: URL(fileURLWithPath: outPath))

                let rtfx = result.duration / max(totalTime, 0.01)
                print("OK \(String(format: "%.1f", result.duration))s RTFx=\(String(format: "%.1f", rtfx)) segs=\(result.segments.count)")
            } catch {
                print("FAIL: \(error)")
            }
        }
    }

    static func formatResult(_ result: MeetingResult, totalTime: Double) -> [String: Any] {
        var json: [String: Any] = [
            "audio": result.audioPath ?? "",
            "duration_s": round(result.duration * 100) / 100,
            "total_processing_s": round(totalTime * 100) / 100,
            "rtfx": round(result.duration / max(totalTime, 0.01) * 10) / 10,
            "n_segments": result.segments.count,
            "n_speakers": Set(result.segments.compactMap { $0.speakerId }).count,
            // full transcript text (for WER/CER comparison)
            "hypothesis": result.segments.map { $0.text }.joined(),
            "segments": result.segments.map { seg in
                [
                    "text": seg.text,
                    "start": round(seg.startTime * 100) / 100,
                    "end": round(seg.endTime * 100) / 100,
                    "speaker": seg.speakerId ?? ""
                ] as [String: Any]
            }
        ]
        // DER-proxy scores against the optional <audio>.speakers.json ground-truth sidecar.
        if let score = benchDiarizationScore(segments: result.segments, audioPath: result.audioPath) {
            json["der_proxy_fer"] = round(score.frameErrorRate * 1000) / 1000
            json["der_proxy_sc_err"] = score.speakerCountError
        }
        return json
    }

    /// Loads the optional `<audio>.speakers.json` diarization ground-truth sidecar next to
    /// `audioPath` (a JSON array of `{"speaker","start","end"}`) and scores the produced segments
    /// against it with the lightweight DER proxy. Returns nil when no valid sidecar exists so
    /// scoring is skipped silently.
    static func benchDiarizationScore(segments: [MeetingSegment], audioPath: String?) -> DiarizationScore? {
        guard let audioPath else { return nil }
        let sidecar = audioPath + ".speakers.json"
        guard let data = FileManager.default.contents(atPath: sidecar) else { return nil }
        let hypothesis = segments.map {
            LabeledInterval(speaker: $0.speakerId ?? "?", start: $0.startTime, end: $0.endTime)
        }
        return scoreDiarizationAgainstSidecar(hypothesis: hypothesis, sidecarJSONData: data)
    }

    static func parseArg(_ args: [String], key: String) -> String? {
        guard let idx = args.firstIndex(of: key), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
#endif
