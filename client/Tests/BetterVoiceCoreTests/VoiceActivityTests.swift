import XCTest
@testable import BetterVoiceCore

final class VoiceActivityTests: XCTestCase {

    // MARK: - Helpers

    private let sampleRate = 16_000

    /// Synthesize a mono buffer: `duration * sampleRate` zeros, then write a sine of
    /// `freq`/`amplitude` into the `[startSec, endSec)` region.
    private func makeBuffer(
        duration: TimeInterval,
        tones: [(startSec: TimeInterval, endSec: TimeInterval, freq: Float, amplitude: Float)]
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(duration * Double(sampleRate)))
        for tone in tones {
            let startIdx = max(0, Int(tone.startSec * Double(sampleRate)))
            let endIdx = min(samples.count, Int(tone.endSec * Double(sampleRate)))
            guard startIdx < endIdx else { continue }
            for i in startIdx..<endIdx {
                let t = Float(i) / Float(sampleRate)
                samples[i] = tone.amplitude * sin(2 * Float.pi * tone.freq * t)
            }
        }
        return samples
    }

    // MARK: - Tests

    func testSilenceYieldsNoIntervals() {
        let samples = makeBuffer(duration: 3.0, tones: [])
        XCTAssertEqual(detectSpeechIntervals(samples: samples, sampleRate: sampleRate), [])
    }

    func testSingleToneInMiddleIsOneInterval() {
        let samples = makeBuffer(
            duration: 3.0,
            tones: [(startSec: 1.0, endSec: 2.0, freq: 440, amplitude: 0.5)]
        )
        let intervals = detectSpeechIntervals(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.start ?? -1, 1.0, accuracy: 0.05)
        XCTAssertEqual(intervals.first?.end ?? -1, 2.0, accuracy: 0.05)
    }

    func testTwoBurstsWithShortGapMerge() {
        // Bursts at [0.5, 0.9) and [1.0, 1.4) — gap of 0.1s < minSilenceSec (0.2s) → merge.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [
                (startSec: 0.5, endSec: 0.9, freq: 440, amplitude: 0.5),
                (startSec: 1.0, endSec: 1.4, freq: 440, amplitude: 0.5),
            ]
        )
        let intervals = detectSpeechIntervals(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?.start ?? -1, 0.5, accuracy: 0.05)
        XCTAssertEqual(intervals.first?.end ?? -1, 1.4, accuracy: 0.05)
    }

    func testTwoBurstsWithLongGapStaySeparate() {
        // Bursts at [0.5, 0.9) and [1.4, 1.8) — gap of 0.5s > minSilenceSec (0.2s) → separate.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [
                (startSec: 0.5, endSec: 0.9, freq: 440, amplitude: 0.5),
                (startSec: 1.4, endSec: 1.8, freq: 440, amplitude: 0.5),
            ]
        )
        let intervals = detectSpeechIntervals(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(intervals.count, 2)
        XCTAssertEqual(intervals[0].start, 0.5, accuracy: 0.05)
        XCTAssertEqual(intervals[0].end, 0.9, accuracy: 0.05)
        XCTAssertEqual(intervals[1].start, 1.4, accuracy: 0.05)
        XCTAssertEqual(intervals[1].end, 1.8, accuracy: 0.05)
    }

    func testAdaptiveNoiseFloorSuppressesNoiseBed() {
        // A low-amplitude noise bed fills the whole 3s buffer; a 0.5-amplitude speech tone
        // overwrites the [1, 2) region. This exercises the *adaptive* branch of the threshold:
        //   - bed RMS  = 0.03 / sqrt(2) ≈ 0.0212  (well above absoluteFloor 0.005)
        //   - tone RMS = 0.5  / sqrt(2) ≈ 0.354
        //   - noiseFloor ≈ bed RMS (bed is the majority of frames), so
        //     threshold ≈ 0.0212 * 3 ≈ 0.0636 — sits between bed RMS and tone RMS.
        // If only absoluteFloor were used, the bed (0.0212 > 0.005) would be detected across
        // the entire buffer, yielding one 0..3s interval. The adaptive floor must suppress the
        // bed and keep only the tone region.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [
                (startSec: 0.0, endSec: 3.0, freq: 60, amplitude: 0.03),   // noise bed
                (startSec: 1.0, endSec: 2.0, freq: 440, amplitude: 0.5),   // speech tone (overwrites bed)
            ]
        )
        let intervals = detectSpeechIntervals(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(intervals.count, 1, "adaptive floor should suppress the noise bed")
        XCTAssertEqual(intervals.first?.start ?? -1, 1.0, accuracy: 0.05)
        XCTAssertEqual(intervals.first?.end ?? -1, 2.0, accuracy: 0.05)
    }

    func testShortBlipBelowMinSpeechIsDropped() {
        // A single 0.1s burst < minSpeechSec (0.2s) → dropped.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [(startSec: 1.0, endSec: 1.1, freq: 440, amplitude: 0.5)]
        )
        XCTAssertEqual(detectSpeechIntervals(samples: samples, sampleRate: sampleRate), [])
    }

    // MARK: - mergeAdjacentSpeechIntervals

    func testMergeAdjacentEmptyYieldsEmpty() {
        XCTAssertEqual(mergeAdjacentSpeechIntervals([], minSilenceSec: 0.20), [])
    }

    func testMergeAdjacentSingleReturnsItself() {
        let one = [SpeechInterval(start: 1.0, end: 2.0)]
        XCTAssertEqual(mergeAdjacentSpeechIntervals(one, minSilenceSec: 0.20), one)
    }

    func testMergeAdjacentGapBelowMinSilenceMerges() {
        // Gap of 0.1s < minSilenceSec (0.2s) → merge into one.
        let intervals = [
            SpeechInterval(start: 0.5, end: 0.9),
            SpeechInterval(start: 1.0, end: 1.4),
        ]
        XCTAssertEqual(
            mergeAdjacentSpeechIntervals(intervals, minSilenceSec: 0.20),
            [SpeechInterval(start: 0.5, end: 1.4)]
        )
    }

    func testMergeAdjacentGapAtOrAboveMinSilenceStaysSeparate() {
        // Gap of 0.5s >= minSilenceSec (0.2s) → stay separate, order preserved.
        let intervals = [
            SpeechInterval(start: 0.5, end: 0.9),
            SpeechInterval(start: 1.4, end: 1.8),
        ]
        XCTAssertEqual(
            mergeAdjacentSpeechIntervals(intervals, minSilenceSec: 0.20),
            intervals
        )
    }

    func testMergeAdjacentTouchingIntervalsMerge() {
        // Boundary case: [0,1] and [1,2] gap 0 → [0,2].
        let intervals = [
            SpeechInterval(start: 0.0, end: 1.0),
            SpeechInterval(start: 1.0, end: 2.0),
        ]
        XCTAssertEqual(
            mergeAdjacentSpeechIntervals(intervals, minSilenceSec: 0.20),
            [SpeechInterval(start: 0.0, end: 2.0)]
        )
    }

    func testMergeAdjacentOverlappingIntervalsMerge() {
        // Overlapping: end taken as max of the two.
        let intervals = [
            SpeechInterval(start: 0.0, end: 1.5),
            SpeechInterval(start: 1.0, end: 1.2),
        ]
        XCTAssertEqual(
            mergeAdjacentSpeechIntervals(intervals, minSilenceSec: 0.20),
            [SpeechInterval(start: 0.0, end: 1.5)]
        )
    }

    // MARK: - detectSpeechIntervalsChunked

    func testChunkedStitchesRunAcrossChunkBoundary() {
        // Tone [0.5, 1.5) spans the boundary of 1.0s chunks ([0,1), [1,2), [2,3)). Each chunk
        // detects only its half; the global boundary-merge must stitch them into ONE interval.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [(startSec: 0.5, endSec: 1.5, freq: 440, amplitude: 0.5)]
        )
        let intervals = detectSpeechIntervalsChunked(samples, sampleRate: sampleRate, chunkSeconds: 1.0)
        XCTAssertEqual(intervals.count, 1, "run split across a chunk boundary should be stitched")
        XCTAssertEqual(intervals.first?.start ?? -1, 0.5, accuracy: 0.05)
        XCTAssertEqual(intervals.first?.end ?? -1, 1.5, accuracy: 0.05)
    }

    func testChunkedMatchesWholeBufferWithinFrameTolerance() {
        // Parity: chunked (1.0s chunks) must match the whole-buffer VAD for a multi-tone buffer,
        // including a tone that straddles a chunk boundary. Asserts offset arithmetic + no
        // fragmentation. Tone2 [1.8, 2.3) crosses the 2.0s boundary.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [
                (startSec: 0.3, endSec: 0.8, freq: 440, amplitude: 0.5),
                (startSec: 1.8, endSec: 2.3, freq: 440, amplitude: 0.5),
            ]
        )
        let whole = detectSpeechIntervals(samples: samples, sampleRate: sampleRate)
        let chunked = detectSpeechIntervalsChunked(samples, sampleRate: sampleRate, chunkSeconds: 1.0)
        XCTAssertEqual(chunked.count, whole.count, "chunked must not fragment vs whole-buffer VAD")
        for (c, w) in zip(chunked, whole) {
            XCTAssertEqual(c.start, w.start, accuracy: 0.05)
            XCTAssertEqual(c.end, w.end, accuracy: 0.05)
        }
    }
}
