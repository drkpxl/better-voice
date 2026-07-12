import XCTest
@testable import BetterVoiceCore

final class BetterVoiceCoreTests: XCTestCase {

    // MARK: - Helpers

    private func seg(
        _ text: String,
        speaker: String?,
        start: TimeInterval = 0,
        name: String? = nil,
        embedding: [Float]? = nil,
        confidence: Double? = nil
    ) -> MeetingSegment {
        MeetingSegment(
            text: text,
            rawText: text,
            startTime: start,
            endTime: start + 1,
            speakerId: speaker,
            l2Kind: .changed,
            isFinal: true,
            speakerName: name,
            speakerEmbedding: embedding,
            speakerConfidence: confidence
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
        XCTAssertEqual(body["think"] as? Bool, false, "thinking stays off (empties local summaries)")
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

    func testResolveSpeakerLabelLocalSpeaker() {
        // Local speaker id with no explicit name renders as the local label, not "Speaker me".
        XCTAssertEqual(
            resolveSpeakerLabel(speakerId: SpeakerIds.local, speakerName: nil, prefix: "Speaker"),
            "You"
        )
        // A blank name is treated as "no name", so the local label still wins.
        XCTAssertEqual(
            resolveSpeakerLabel(speakerId: SpeakerIds.local, speakerName: "  ", prefix: "Speaker"),
            "You"
        )
        // An explicit name always wins over the local label.
        XCTAssertEqual(
            resolveSpeakerLabel(speakerId: SpeakerIds.local, speakerName: "Steven", prefix: "Speaker"),
            "Steven"
        )
        // The local label is caller-supplied (for localization); default is "You".
        XCTAssertEqual(
            resolveSpeakerLabel(speakerId: SpeakerIds.local, speakerName: nil, prefix: "Speaker", localLabel: "Moi"),
            "Moi"
        )
        // A normal numeric id is unaffected by the local-speaker special case.
        XCTAssertEqual(
            resolveSpeakerLabel(speakerId: "1", speakerName: nil, prefix: "Speaker", localLabel: "Moi"),
            "Speaker 1"
        )
    }

    func testSpeakerLabelLocalSpeaker() {
        XCTAssertEqual(seg("hi", speaker: SpeakerIds.local).speakerLabel(prefix: "Speaker"), "You")
        XCTAssertEqual(
            seg("hi", speaker: SpeakerIds.local, name: "Steven").speakerLabel(prefix: "Speaker"),
            "Steven"
        )
        XCTAssertEqual(
            seg("hi", speaker: SpeakerIds.local).speakerLabel(prefix: "Speaker", localLabel: "Yo"),
            "Yo"
        )
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

    func testMeetingSegmentRoundTripsEmbeddingAndConfidence() {
        let s = seg("hi", speaker: "1", embedding: [0.1, 0.2, 0.3], confidence: 0.87)
        XCTAssertEqual(s.speakerEmbedding, [0.1, 0.2, 0.3])
        XCTAssertEqual(s.speakerConfidence, 0.87)
    }

    func testMeetingSegmentDefaultsEmbeddingAndConfidenceToNil() {
        let s = seg("hi", speaker: "1")
        XCTAssertNil(s.speakerEmbedding)
        XCTAssertNil(s.speakerConfidence)
    }

    func testApplySpeakerNamesPreservesEmbeddingAndConfidence() {
        let segs = [seg("hi", speaker: "1", embedding: [0.4, 0.5], confidence: 0.42)]
        let named = applySpeakerNames(["1": "Steven"], to: segs)
        XCTAssertEqual(named[0].speakerName, "Steven")
        XCTAssertEqual(named[0].speakerEmbedding, [0.4, 0.5])
        XCTAssertEqual(named[0].speakerConfidence, 0.42)
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

    func testSampleQuotesPicksLongestTurnsInChronologicalOrder() {
        let segs = [
            seg("this is the longest turn speaker one said", speaker: "1", start: 30), // longest
            seg("second longest turn here", speaker: "1", start: 10),                 // 2nd
            seg("third turn", speaker: "1", start: 20),                               // 3rd
            seg("tiny", speaker: "1", start: 40),                                     // dropped (only 3 kept)
            seg("only turn", speaker: "2", start: 5),
        ]
        let quotes = sampleQuotes(segs, perSpeaker: 3, maxLen: 160)
        // Speaker 1: the three longest turns, returned in start order (10, 20, 30).
        XCTAssertEqual(quotes["1"], [
            "second longest turn here",
            "third turn",
            "this is the longest turn speaker one said",
        ])
        XCTAssertEqual(quotes["2"], ["only turn"])
    }

    func testSampleQuotesSkipsEmptyAndDedupes() {
        let segs = [
            seg("hello", speaker: "1", start: 0),
            seg("   ", speaker: "1", start: 1),
            seg("hello", speaker: "1", start: 2), // duplicate text
            seg("world", speaker: "1", start: 3),
        ]
        let quotes = sampleQuotes(segs, perSpeaker: 3, maxLen: 160)
        XCTAssertEqual(quotes["1"], ["hello", "world"], "blank skipped, duplicate collapsed")
    }

    func testSampleQuotesTruncates() {
        let long = String(repeating: "x", count: 100)
        let quotes = sampleQuotes([seg(long, speaker: "1")], perSpeaker: 3, maxLen: 10)
        XCTAssertEqual(quotes["1"]?.first?.count, 11) // 10 chars + ellipsis
        XCTAssertTrue(quotes["1"]?.first?.hasSuffix("…") ?? false)
    }

    // MARK: - Two-file meeting capture: mergeSpeakerTimelines

    func testMergeSpeakerTimelinesInterleavesByStartTime() {
        let local = [seg("hi there", speaker: nil, start: 5), seg("yeah agreed", speaker: nil, start: 15)]
        let remote = [seg("hello", speaker: "1", start: 0), seg("sure", speaker: "1", start: 10)]
        let merged = mergeSpeakerTimelines(localSegments: local, remoteSegments: remote)
        XCTAssertEqual(merged.map(\.text), ["hello", "hi there", "sure", "yeah agreed"])
        XCTAssertEqual(merged.map(\.startTime), [0, 5, 10, 15])
    }

    func testMergeSpeakerTimelinesLabelsLocalSegmentsAsLocalSpeaker() {
        // .single-mode output always has a nil speakerId, but the merge stamps SpeakerIds.local
        // regardless of whatever the segment already carried.
        let local = [seg("hi", speaker: nil, start: 0), seg("stray id", speaker: "1", start: 1)]
        let merged = mergeSpeakerTimelines(localSegments: local, remoteSegments: [])
        XCTAssertEqual(merged.map(\.speakerId), [SpeakerIds.local, SpeakerIds.local])
    }

    func testMergeSpeakerTimelinesPreservesRemoteSpeakerIds() {
        let remote = [seg("a", speaker: "1", start: 0), seg("b", speaker: "2", start: 1)]
        let merged = mergeSpeakerTimelines(localSegments: [], remoteSegments: remote)
        XCTAssertEqual(merged.map(\.speakerId), ["1", "2"])
    }

    func testMergeSpeakerTimelinesLocalLabelResolvesWithoutNaming() {
        // The merged local segment renders with the configured local label even though it was
        // never touched by the naming step (no speakerName set) — the local user is
        // pre-identified purely from being on the mic channel.
        let local = [seg("hi", speaker: nil, start: 0)]
        let merged = mergeSpeakerTimelines(localSegments: local, remoteSegments: [])
        XCTAssertEqual(merged[0].speakerLabel(prefix: "Speaker", localLabel: "Steven"), "Steven")
    }

    func testMergeSpeakerTimelinesEmptyRemoteReturnsOnlyLocal() {
        let local = [seg("a", speaker: nil, start: 2), seg("b", speaker: nil, start: 1)]
        let merged = mergeSpeakerTimelines(localSegments: local, remoteSegments: [])
        XCTAssertEqual(merged.map(\.text), ["b", "a"])
        XCTAssertEqual(merged.map(\.speakerId), [SpeakerIds.local, SpeakerIds.local])
    }

    func testMergeSpeakerTimelinesEmptyLocalReturnsOnlyRemote() {
        let remote = [seg("a", speaker: "2", start: 2), seg("b", speaker: "1", start: 1)]
        let merged = mergeSpeakerTimelines(localSegments: [], remoteSegments: remote)
        XCTAssertEqual(merged.map(\.text), ["b", "a"])
    }

    func testMergeSpeakerTimelinesBothEmptyReturnsEmpty() {
        XCTAssertTrue(mergeSpeakerTimelines(localSegments: [], remoteSegments: []).isEmpty)
    }

    func testMergeSpeakerTimelinesTieBreaksLocalBeforeRemote() {
        // Documented contract: on an equal start time, the local turn orders before the remote
        // one. Locks the stable-sort + `local + remote` concatenation order so a future refactor
        // to a non-stable sort would fail here rather than silently reordering turns.
        let local = [seg("me first", speaker: nil, start: 10)]
        let remote = [seg("them at same time", speaker: "1", start: 10)]
        let merged = mergeSpeakerTimelines(localSegments: local, remoteSegments: remote)
        XCTAssertEqual(merged.map(\.text), ["me first", "them at same time"])
        XCTAssertEqual(merged.map(\.speakerId), [SpeakerIds.local, "1"])
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

    // MARK: - Summary title extraction

    func testParseSummaryTitleExtractsLeadingTitleLine() {
        let raw = "TITLE: Q3 Roadmap Sync\n\n## Summary\nWe discussed the roadmap."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertEqual(title, "Q3 Roadmap Sync")
        XCTAssertEqual(markdown, "## Summary\nWe discussed the roadmap.")
    }

    func testParseSummaryTitleIsCaseInsensitive() {
        let raw = "title: Weekly Status\n\nBody text."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertEqual(title, "Weekly Status")
        XCTAssertEqual(markdown, "Body text.")
    }

    func testParseSummaryTitleWithoutBlankLineAfter() {
        let raw = "TITLE: Weekly Status\n## Summary\nBody."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertEqual(title, "Weekly Status")
        XCTAssertEqual(markdown, "## Summary\nBody.")
    }

    func testParseSummaryTitleReturnsNilWhenNoTitleLine() {
        let raw = "## Summary\nJust a normal summary, no title line."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertNil(title)
        XCTAssertEqual(markdown, raw, "response is returned byte-identical when there's no title to extract")
    }

    func testParseSummaryTitleReturnsNilForEmptyTitleValue() {
        let raw = "TITLE:\n\n## Summary\nBody."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertNil(title)
        XCTAssertEqual(markdown, raw)
    }

    func testParseSummaryTitleHandlesLeadingBlankLines() {
        let raw = "\n\nTITLE: Weekly Status\n\nBody text."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertEqual(title, "Weekly Status")
        XCTAssertEqual(markdown, "Body text.")
    }

    func testParseSummaryTitleReturnsNilForEmptyResponse() {
        let (title, markdown) = parseSummaryTitle(from: "")
        XCTAssertNil(title)
        XCTAssertEqual(markdown, "")
    }

    func testParseSummaryTitleStripsBoldWrappedMarker() {
        let (title, markdown) = parseSummaryTitle(from: "**TITLE:** Q3 Roadmap Sync\n\nBody.")
        XCTAssertEqual(title, "Q3 Roadmap Sync")
        XCTAssertEqual(markdown, "Body.")
    }

    func testParseSummaryTitleStripsFullyBoldedTitleLine() {
        let (title, markdown) = parseSummaryTitle(from: "**TITLE: Q3 Roadmap Sync**\n\nBody.")
        XCTAssertEqual(title, "Q3 Roadmap Sync")
        XCTAssertEqual(markdown, "Body.")
    }

    func testParseSummaryTitleStripsHeadingWrappedMarker() {
        let (title, markdown) = parseSummaryTitle(from: "## TITLE: Q3 Roadmap Sync\n\nBody.")
        XCTAssertEqual(title, "Q3 Roadmap Sync")
        XCTAssertEqual(markdown, "Body.")
    }

    func testParseSummaryTitleTitleOnlyResponseYieldsEmptyMarkdown() {
        // The client layer (summarizeWithTitle) treats an empty post-strip body as a
        // summarization failure — this just pins the parser's contract for that case.
        let (title, markdown) = parseSummaryTitle(from: "TITLE: Q3 Roadmap Sync")
        XCTAssertEqual(title, "Q3 Roadmap Sync")
        XCTAssertEqual(markdown, "")
    }

    func testParseSummaryTitleOnlyStripsOneBlankLineAfterTitle() {
        // Blank lines *within* the body (beyond the single separator) are preserved verbatim.
        let raw = "TITLE: Weekly Status\n\n\nFirst.\n\nSecond."
        let (title, markdown) = parseSummaryTitle(from: raw)
        XCTAssertEqual(title, "Weekly Status")
        XCTAssertEqual(markdown, "\nFirst.\n\nSecond.")
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
}
