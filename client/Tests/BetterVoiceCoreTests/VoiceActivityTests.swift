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

    func testShortBlipBelowMinSpeechIsDropped() {
        // A single 0.1s burst < minSpeechSec (0.2s) → dropped.
        let samples = makeBuffer(
            duration: 3.0,
            tones: [(startSec: 1.0, endSec: 1.1, freq: 440, amplitude: 0.5)]
        )
        XCTAssertEqual(detectSpeechIntervals(samples: samples, sampleRate: sampleRate), [])
    }
}
