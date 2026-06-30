import XCTest
@testable import WECore

final class WECoreTests: XCTestCase {

    // MARK: - Helpers

    private func seg(
        _ text: String,
        speaker: String?,
        start: TimeInterval = 0,
        name: String? = nil
    ) -> MeetingSegment {
        MeetingSegment(
            text: text,
            rawText: text,
            startTime: start,
            endTime: start + 1,
            speakerId: speaker,
            l2Kind: .changed,
            isFinal: true,
            speakerName: name
        )
    }

    // MARK: - Prompt-template selection

    func testResolveSummarizationPromptUsesBuiltinByDefault() {
        let builtin: (MeetingType) -> String = { "builtin-\($0.configKey)" }
        XCTAssertEqual(resolveSummarizationPrompt(type: .standup, overrides: [:], builtin: builtin), "builtin-standup")
    }

    func testResolveSummarizationPromptOverrideWins() {
        let builtin: (MeetingType) -> String = { "builtin-\($0.configKey)" }
        let overrides = ["one_on_one": "custom 1:1 prompt"]
        XCTAssertEqual(resolveSummarizationPrompt(type: .oneOnOne, overrides: overrides, builtin: builtin), "custom 1:1 prompt")
    }

    func testResolveSummarizationPromptBlankOverrideFallsBack() {
        let builtin: (MeetingType) -> String = { "builtin-\($0.configKey)" }
        let overrides = ["general": "   "]
        XCTAssertEqual(resolveSummarizationPrompt(type: .general, overrides: overrides, builtin: builtin), "builtin-general")
    }

    // MARK: - MeetingType

    func testMeetingTypeFromConfigKey() {
        XCTAssertEqual(MeetingType.from(configKey: "general"), .general)
        XCTAssertEqual(MeetingType.from(configKey: "one_on_one"), .oneOnOne)
        XCTAssertEqual(MeetingType.from(configKey: "standup"), .standup)
        XCTAssertEqual(MeetingType.from(configKey: "  STANDUP "), .standup)
        XCTAssertNil(MeetingType.from(configKey: "nonsense"))
    }

    // MARK: - Classification parsing

    func testParseMeetingType() {
        XCTAssertEqual(parseMeetingType(from: "This is a 1:1", default: .general), .oneOnOne)
        XCTAssertEqual(parseMeetingType(from: "ONE ON ONE meeting", default: .general), .oneOnOne)
        XCTAssertEqual(parseMeetingType(from: "Daily standup", default: .general), .standup)
        XCTAssertEqual(parseMeetingType(from: "weekly status update", default: .general), .standup)
        XCTAssertEqual(parseMeetingType(from: "General discussion", default: .standup), .general)
        XCTAssertEqual(parseMeetingType(from: "asdfgh garbage", default: .general), .general)
        XCTAssertEqual(parseMeetingType(from: "asdfgh garbage", default: .standup), .standup)
    }

    func testParseMeetingTypePrefersOneOnOneOverStatus() {
        // A response mentioning both should resolve deterministically (1:1 checked first).
        XCTAssertEqual(parseMeetingType(from: "a 1:1 status check", default: .general), .oneOnOne)
    }

    // MARK: - Ollama request building

    func testMakeOllamaRequestBody() {
        let body = makeOllamaRequestBody(
            model: "qwen3:8b",
            system: "sys",
            prompt: "hello",
            numCtx: 16384,
            numPredict: 1024,
            temperature: 0
        )
        XCTAssertEqual(body["model"] as? String, "qwen3:8b")
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertEqual(body["prompt"] as? String, "hello")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let opts = try? XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(opts?["num_ctx"] as? Int, 16384)
        XCTAssertEqual(opts?["num_predict"] as? Int, 1024)
        XCTAssertEqual(opts?["temperature"] as? Double, 0)
    }

    // MARK: - Speaker labeling

    func testResolveSpeakerLabel() {
        XCTAssertEqual(resolveSpeakerLabel(speakerId: "1", speakerName: nil, prefix: "Speaker"), "Speaker 1")
        XCTAssertEqual(resolveSpeakerLabel(speakerId: "1", speakerName: "Steven", prefix: "Speaker"), "Steven")
        XCTAssertEqual(resolveSpeakerLabel(speakerId: "1", speakerName: "  ", prefix: "Speaker"), "Speaker 1")
        XCTAssertNil(resolveSpeakerLabel(speakerId: nil, speakerName: nil, prefix: "Speaker"))
    }

    func testApplySpeakerNames() {
        let segs = [seg("hi", speaker: "1"), seg("yo", speaker: "2"), seg("no id", speaker: nil)]
        let named = applySpeakerNames(["1": "Steven", "2": "  "], to: segs)
        XCTAssertEqual(named[0].speakerName, "Steven")
        XCTAssertNil(named[1].speakerName, "blank name should not be applied")
        XCTAssertNil(named[2].speakerName)
        XCTAssertEqual(named[0].speakerLabel(prefix: "Speaker"), "Steven")
        XCTAssertEqual(named[1].speakerLabel(prefix: "Speaker"), "Speaker 2")
    }

    func testOrderedUniqueSpeakerIds() {
        let segs = [seg("a", speaker: "2"), seg("b", speaker: "1"), seg("c", speaker: "2"), seg("d", speaker: nil)]
        XCTAssertEqual(orderedUniqueSpeakerIds(segs), ["2", "1"])
    }

    func testSampleSnippetsPicksLongestTurn() {
        let segs = [
            seg("short", speaker: "1"),
            seg("a much longer turn from speaker one", speaker: "1"),
            seg("only", speaker: "2"),
        ]
        let snippets = sampleSnippets(segs, maxLen: 80)
        XCTAssertEqual(snippets["1"], "a much longer turn from speaker one")
        XCTAssertEqual(snippets["2"], "only")
    }

    func testSampleSnippetsTruncates() {
        let long = String(repeating: "x", count: 100)
        let snippets = sampleSnippets([seg(long, speaker: "1")], maxLen: 10)
        XCTAssertEqual(snippets["1"]?.count, 11) // 10 chars + ellipsis
        XCTAssertTrue(snippets["1"]?.hasSuffix("…") ?? false)
    }

    // MARK: - Transcript building

    func testBuildSummarizationTranscript() {
        let segs = [
            seg("hello there", speaker: "1", name: "Steven"),
            seg("hi steven", speaker: "2"),
            seg("", speaker: "1"),
        ]
        let out = buildSummarizationTranscript(segments: segs, speakerPrefix: "Speaker")
        XCTAssertEqual(out, "Steven: hello there\nSpeaker 2: hi steven")
    }

    // MARK: - Markdown rendering

    func testRenderTranscriptMarkdownGroupsBySpeaker() {
        let segs = [
            seg("first", speaker: "1", start: 0, name: "Steven"),
            seg("second", speaker: "1", start: 65),
            seg("reply", speaker: "2", start: 70),
        ]
        let md = MeetingMarkdown.renderTranscript(
            title: "Meeting Transcript",
            metadataLines: ["Date: 2026-06-30"],
            segments: segs,
            speakerPrefix: "Speaker",
            unknownLabel: "Unknown"
        )
        XCTAssertTrue(md.contains("# Meeting Transcript"))
        XCTAssertTrue(md.contains("- Date: 2026-06-30"))
        XCTAssertTrue(md.contains("### Steven"))
        XCTAssertTrue(md.contains("### Speaker 2"))
        XCTAssertTrue(md.contains("`00:00` first"))
        XCTAssertTrue(md.contains("`01:05` second"))
        XCTAssertTrue(md.contains("`01:10` reply"))
        // Steven header should appear once (both speaker-1 turns share it).
        XCTAssertEqual(md.components(separatedBy: "### Steven").count - 1, 1)
    }

    func testRenderTranscriptUsesUnknownLabel() {
        let md = MeetingMarkdown.renderTranscript(
            title: "T",
            metadataLines: [],
            segments: [seg("x", speaker: nil)],
            speakerPrefix: "Speaker",
            unknownLabel: "Unknown"
        )
        XCTAssertTrue(md.contains("### Unknown"))
    }

    func testRenderSummaryMarkdown() {
        let md = MeetingMarkdown.renderSummary(
            title: "Meeting Summary",
            metadataLines: ["Type: 1:1", "Date: 2026-06-30"],
            summary: "  Key points discussed.\n"
        )
        XCTAssertTrue(md.hasPrefix("# Meeting Summary\n"))
        XCTAssertTrue(md.contains("- Type: 1:1"))
        XCTAssertTrue(md.contains("Key points discussed."))
    }

    // MARK: - Waveform math

    func testRMSZeroForSilence() {
        XCTAssertEqual(WaveformMath.rms(int16: [Int16](repeating: 0, count: 64)), 0, accuracy: 1e-6)
        XCTAssertEqual(WaveformMath.rms(int16: []), 0)
    }

    func testRMSFullScale() {
        let buf = [Int16](repeating: 32767, count: 128)
        XCTAssertEqual(WaveformMath.rms(int16: buf), 1.0, accuracy: 0.001)
    }

    func testNormalizedLevelFloor() {
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 0.01, noiseFloor: 0.02, sensitivity: 1), 0)
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 0.02, noiseFloor: 0.02, sensitivity: 1), 0)
    }

    func testNormalizedLevelScalesAndClamps() {
        // Halfway between floor and 1, sensitivity 1.
        let mid = WaveformMath.normalizedLevel(rms: 0.51, noiseFloor: 0.02, sensitivity: 1)
        XCTAssertEqual(mid, 0.5, accuracy: 0.01)
        // High sensitivity clamps at 1.
        XCTAssertEqual(WaveformMath.normalizedLevel(rms: 0.5, noiseFloor: 0.02, sensitivity: 10), 1)
    }
}
