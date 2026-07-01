import Foundation

/// A half-open time interval `[start, end)` (seconds) during which speech is present.
public struct SpeechInterval: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Energy-based voice-activity detection for a mono PCM buffer.
///
/// Splits the buffer into fixed-length RMS frames, estimates a noise floor from a
/// low percentile of the frame energies, marks frames above an adaptive threshold as
/// speech, then applies hangover merging (fill short silent gaps) and a minimum-duration
/// filter (drop short bursts). Returns the resulting speech intervals in seconds.
///
/// This is intended for attributing mic-channel energy to the local "me" speaker without
/// running a diarization model on it.
///
/// Noise-floor estimator: the 10th percentile of all frame RMS values (nearest-rank).
/// This is robust to a small amount of speech in an otherwise-quiet mic channel — the bulk
/// of frames are silence/room-tone, so a low percentile tracks the ambient floor. Silence
/// (or any buffer whose 10th-percentile RMS is tiny) stays below `absoluteFloor`, so the
/// `max(absoluteFloor, ...)` guard prevents amplifying pure noise into false speech.
///
/// - Parameters:
///   - samples: mono PCM samples (typically normalized to roughly -1...1).
///   - sampleRate: samples per second (e.g. 16000).
///   - frameSec: RMS frame length in seconds (default 30 ms).
///   - minSpeechSec: minimum duration of a kept speech run; shorter runs are dropped.
///   - minSilenceSec: silent gaps shorter than this are merged into one run (hangover).
///   - absoluteFloor: RMS at or below this is always treated as silence.
///   - noiseMultiplier: speech threshold = max(absoluteFloor, noiseFloor * noiseMultiplier).
/// - Returns: speech intervals sorted by start time. Empty/all-silence input → `[]`.
public func detectSpeechIntervals(
    samples: [Float],
    sampleRate: Int,
    frameSec: TimeInterval = 0.03,        // 30 ms RMS frames
    minSpeechSec: TimeInterval = 0.20,    // drop bursts shorter than this
    minSilenceSec: TimeInterval = 0.20,   // merge gaps shorter than this (hangover)
    absoluteFloor: Float = 0.005,         // RMS below this is always silence
    noiseMultiplier: Float = 3.0          // speech threshold = max(absoluteFloor, noiseFloor * noiseMultiplier)
) -> [SpeechInterval] {
    guard sampleRate > 0, frameSec > 0, !samples.isEmpty else { return [] }

    let frameSize = max(1, Int((frameSec * Double(sampleRate)).rounded()))
    let totalDuration = TimeInterval(samples.count) / TimeInterval(sampleRate)

    // 1 & 2. Split into consecutive frames (include a non-empty trailing frame) and compute RMS.
    var frameRMS: [Float] = []
    frameRMS.reserveCapacity(samples.count / frameSize + 1)
    var index = 0
    while index < samples.count {
        let end = min(index + frameSize, samples.count)
        var sumSquares: Double = 0
        for i in index..<end {
            let v = Double(samples[i])
            sumSquares += v * v
        }
        let mean = sumSquares / Double(end - index)
        frameRMS.append(Float(mean.squareRoot()))
        index += frameSize
    }
    guard !frameRMS.isEmpty else { return [] }

    // 3. Noise floor: 10th percentile of frame RMS values (nearest-rank).
    let sorted = frameRMS.sorted()
    let rank = Int((0.10 * Double(sorted.count - 1)).rounded())
    let noiseFloor = sorted[min(max(rank, 0), sorted.count - 1)]

    // 4. Adaptive threshold; classify each frame as speech.
    let threshold = max(absoluteFloor, noiseFloor * noiseMultiplier)

    // 5a. Build contiguous speech runs as [firstFrame, lastFrame] index ranges.
    var runs: [(first: Int, last: Int)] = []
    var runStart: Int? = nil
    for (i, rms) in frameRMS.enumerated() {
        if rms >= threshold {
            if runStart == nil { runStart = i }
        } else if let s = runStart {
            runs.append((first: s, last: i - 1))
            runStart = nil
        }
    }
    if let s = runStart {
        runs.append((first: s, last: frameRMS.count - 1))
    }
    guard !runs.isEmpty else { return [] }

    // 5b. Merge runs whose silent gap (in frames) is < minSilenceSec (hangover).
    let minSilenceFrames = Int((minSilenceSec / frameSec).rounded())
    var merged: [(first: Int, last: Int)] = [runs[0]]
    for run in runs.dropFirst() {
        let gapFrames = run.first - merged[merged.count - 1].last - 1
        if gapFrames < minSilenceFrames {
            merged[merged.count - 1].last = run.last
        } else {
            merged.append(run)
        }
    }

    // 5c. Drop runs shorter than minSpeechSec, then convert frame indices to times.
    var intervals: [SpeechInterval] = []
    for run in merged {
        let start = TimeInterval(run.first) * frameSec
        let end = min(TimeInterval(run.last + 1) * frameSec, totalDuration)
        if end - start >= minSpeechSec {
            intervals.append(SpeechInterval(start: start, end: end))
        }
    }

    // 6 & 7. Already sorted by construction (runs are built left-to-right).
    return intervals
}
