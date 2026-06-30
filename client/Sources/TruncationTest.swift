@preconcurrency import AVFoundation
import Speech

/// Truncation test: simulates VoiceSession's streaming input + stop() logic
/// Verifies whether SA loses trailing content during the stop sequence
///
/// Usage: BetterVoice --test-truncation <wav-file> [--locale zh-CN]
///
/// Test flow:
/// 1. Read the WAV file and slice it into small buffers in 20ms chunks (simulating AVCaptureSession's live input)
/// 2. Feed the chunks to SpeechAnalyzer via AsyncStream (the exact same path VoiceSession uses)
/// 3. Once all buffers are sent, run the same shutdown logic as VoiceSession.stop()
/// 4. Log the timestamp and SA state at each step, then print a diagnostic report
enum TruncationTest {
    private static let outputURL = BetterVoiceDataDir.archiveReports.appendingPathComponent("truncation-test.log")
    nonisolated(unsafe) private static var logHandle: FileHandle?

    private static func log(_ msg: String) {
        let line = msg + "\n"
        print(msg)
        fflush(stdout)
        if let data = line.data(using: .utf8) {
            logHandle?.write(data)
        }
    }

    @MainActor
    static func run() async {
        // Initialize the log file
        BetterVoiceDataDir.ensureExists()
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: outputURL)

        let args = CommandLine.arguments

        guard let idx = args.firstIndex(of: "--test-truncation"), idx + 1 < args.count else {
            log("Usage: BetterVoice --test-truncation <wav-file> [--locale zh-CN]")
            return
        }

        let wavPath = args[idx + 1]
        let locale = Locale(identifier: MeetingBenchmark.parseArg(args, key: "--locale") ?? "zh-CN")

        guard FileManager.default.fileExists(atPath: wavPath) else {
            log("Error: file not found: \(wavPath)")
            return
        }

        log("=== Truncation Test ===")
        log("Audio: \(wavPath)")
        log("Locale: \(locale.identifier(.bcp47))")
        log("")

        do {
            // Read the audio file
            let fileURL = URL(fileURLWithPath: wavPath)
            let audioFile = try AVAudioFile(forReading: fileURL)
            let fileFormat = audioFile.processingFormat
            let totalFrames = AVAudioFrameCount(audioFile.length)
            let audioDuration = Double(totalFrames) / fileFormat.sampleRate
            log("Audio: \(String(format: "%.1f", audioDuration))s, \(Int(fileFormat.sampleRate))Hz, \(fileFormat.channelCount)ch")

            // Read the full audio into a buffer
            let fullBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: totalFrames)!
            try audioFile.read(into: fullBuffer)

            // Configure SA (same as VoiceSession)
            let supportedLocales = await SpeechTranscriber.supportedLocales
            let bestLocale = supportedLocales.first(where: { $0.identifier(.bcp47).hasPrefix("zh") }) ?? locale

            let transcriber = SpeechTranscriber(
                locale: bestLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .alternativeTranscriptions],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            log("SA format: \(analyzerFormat as Any)")

            // Format converter (if needed)
            var converter: AVAudioConverter? = nil
            if let targetFormat = analyzerFormat,
               fileFormat.sampleRate != targetFormat.sampleRate
                || fileFormat.commonFormat != targetFormat.commonFormat {
                converter = AVAudioConverter(from: fileFormat, to: targetFormat)
                log("Converter: \(fileFormat) → \(targetFormat)")
            }

            // Create the AsyncStream (same as VoiceSession)
            let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

            // Start SA
            try await analyzer.start(inputSequence: inputSequence)
            log("SA started")

            // Result collection
            var finalizedText = ""
            var volatileText = ""
            var finalCount = 0
            var volatileCount = 0
            var lastFinalTime: TimeInterval = 0

            let resultTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)

                        if result.isFinal {
                            finalizedText += text
                            volatileText = ""
                            finalCount += 1

                            // Extract the time range
                            typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute
                            var maxEnd: TimeInterval = 0
                            for (timeRange, _) in result.text.runs[TimeKey.self] {
                                if let range = timeRange {
                                    let end = range.start.seconds + range.duration.seconds
                                    if end > maxEnd { maxEnd = end }
                                }
                            }
                            lastFinalTime = max(lastFinalTime, maxEnd)
                            log("  [FINAL #\(finalCount)] \(String(format: "%.1f", maxEnd))s: \(text.prefix(50))...")
                        } else {
                            volatileText = text
                            volatileCount += 1
                        }
                    }
                    log("  [RESULT STREAM ENDED NORMALLY]")
                } catch is CancellationError {
                    log("  [RESULT STREAM CANCELLED]")
                } catch {
                    log("  [RESULT STREAM ERROR: \(error)]")
                }
            }

            // === Simulate streaming input: slice into 20ms chunks and yield ===
            // Note: feed runs inside a nonisolated Task to avoid blocking the MainActor
            let chunkDuration: TimeInterval = 0.02 // 20ms, simulating AVCaptureSession
            let chunkFrames = AVAudioFrameCount(fileFormat.sampleRate * chunkDuration)
            let feedStartTime = CFAbsoluteTimeGetCurrent()

            let feedResult = await Task.detached { () -> (Int, TimeInterval) in
                var offset: AVAudioFrameCount = 0
                var yieldCount = 0

                while offset < totalFrames {
                    let remaining = totalFrames - offset
                    let framesToRead = min(chunkFrames, remaining)

                    guard let chunk = fullBuffer.slice(from: offset, length: framesToRead) else { break }

                    let outputChunk: AVAudioPCMBuffer
                    if let converter, let targetFormat = analyzerFormat {
                        let ratio = targetFormat.sampleRate / fileFormat.sampleRate
                        let outCapacity = AVAudioFrameCount(Double(framesToRead) * ratio) + 1
                        let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)!
                        var error: NSError?
                        let consumed = Box(false)
                        converter.convert(to: outBuf, error: &error) { _, outStatus in
                            if consumed.value { outStatus.pointee = .noDataNow; return nil }
                            consumed.value = true
                            outStatus.pointee = .haveData
                            return chunk
                        }
                        outputChunk = outBuf
                    } else {
                        outputChunk = chunk
                    }

                    let input = AnalyzerInput(buffer: outputChunk)
                    inputBuilder.yield(input)
                    yieldCount += 1

                    offset += framesToRead
                }

                let yieldedDuration = Double(totalFrames) / fileFormat.sampleRate
                return (yieldCount, yieldedDuration)
            }.value

            let yieldCount = feedResult.0
            let yieldedDuration = feedResult.1
            let feedTime = CFAbsoluteTimeGetCurrent() - feedStartTime
            log("")
            log("=== Feed complete ===")
            log("Yielded: \(yieldCount) chunks, \(String(format: "%.1f", yieldedDuration))s audio in \(String(format: "%.2f", feedTime))s")
            log("Feed speed: \(String(format: "%.1f", yieldedDuration / feedTime))x realtime")
            log("")

            // === Simulate VoiceSession.stop()'s shutdown logic ===
            log("=== Simulating stop() flow ===")

            // Step 1: finish input stream
            let t1 = CFAbsoluteTimeGetCurrent()
            inputBuilder.finish()
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t1))s] inputBuilder.finish()")

            // Step 2: finalize with 5s timeout (same as VoiceSession)
            let t2 = CFAbsoluteTimeGetCurrent()
            do {
                try await withThrowingTimeout(seconds: 5) {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t2))s] finalizeAndFinishThroughEndOfInput() completed")
            } catch {
                log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t2))s] finalizeAndFinishThroughEndOfInput() TIMEOUT/ERROR: \(error)")
            }

            // Step 3: sleep 500ms (same as VoiceSession)
            let t3 = CFAbsoluteTimeGetCurrent()
            try? await Task.sleep(for: .milliseconds(500))
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t3))s] sleep(500ms)")

            // Step 4: cancel resultTask (same as VoiceSession)
            let t4 = CFAbsoluteTimeGetCurrent()
            resultTask.cancel()
            log("[\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t4))s] resultTask.cancel()")

            // Wait for resultTask to finish
            await resultTask.value

            // === Print the diagnostic report ===
            let fullText = finalizedText + volatileText
            log("")
            log(String(repeating: "=", count: 60))
            log("Truncation Test Report")
            log(String(repeating: "=", count: 60))
            log("Total audio duration:   \(String(format: "%.1f", audioDuration))s")
            log("SA last final time:     \(String(format: "%.1f", lastFinalTime))s")
            log("Trailing gap:           \(String(format: "%.1f", audioDuration - lastFinalTime))s")
            log("")
            log("Final segments:    \(finalCount)")
            log("Volatile updates:  \(volatileCount)")
            log("finalizedText:     \(finalizedText.count) chars")
            log("volatileText:      \(volatileText.count) chars")
            log("fullText:          \(fullText.count) chars")
            log("")
            log("=== finalizedText (first 200 chars) ===")
            log(String(finalizedText.prefix(200)))
            log("")
            log("=== volatileText ===")
            log(volatileText.isEmpty ? "(empty)" : volatileText)
            log("")
            log("=== fullText last 100 chars ===")
            log(String(fullText.suffix(100)))
            log("")

            // If a ground truth file exists, compare against it
            let gtPath = wavPath.replacingOccurrences(of: ".wav", with: ".txt")
            if FileManager.default.fileExists(atPath: gtPath) {
                let gt = try String(contentsOfFile: gtPath, encoding: .utf8)
                    .replacingOccurrences(of: "\n", with: "")
                    .replacingOccurrences(of: " ", with: "")
                let fullClean = fullText.replacingOccurrences(of: " ", with: "")

                log("=== Ground Truth Comparison ===")
                log("GT char count:   \(gt.count)")
                log("SA char count:   \(fullClean.count)")
                log("")
                log("GT last 50 chars:  \(String(gt.suffix(50)))")
                log("SA last 50 chars:  \(String(fullClean.suffix(50)))")
                log("")

                // Check whether the GT's last 20 characters appear in the SA output
                let gtTail = String(gt.suffix(20))
                let found = fullClean.contains(gtTail)
                log("GT tail 20 chars: \"\(gtTail)\"")
                log("Found in SA output: \(found ? "yes (not truncated)" : "no (possibly truncated)")")
            }

        } catch {
            log("Error: \(error)")
        }
    }
}

// MARK: - AVAudioPCMBuffer slice helper

extension AVAudioPCMBuffer {
    /// Slices a buffer segment starting at the given offset
    func slice(from startFrame: AVAudioFrameCount, length: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard startFrame + length <= frameLength else { return nil }
        guard let newBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { return nil }
        newBuf.frameLength = length

        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        let srcOffset = Int(startFrame) * Int(bytesPerFrame)
        let byteCount = Int(length) * Int(bytesPerFrame)

        guard let srcData = audioBufferList.pointee.mBuffers.mData,
              let dstData = newBuf.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        dstData.copyMemory(from: srcData.advanced(by: srcOffset), byteCount: byteCount)
        return newBuf
    }
}
