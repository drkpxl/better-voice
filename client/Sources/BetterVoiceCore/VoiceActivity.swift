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
/// Precondition: the input channel is assumed to be **majority silence** — its intended use
/// is the meeting mic channel, where the local user speaks intermittently and most frames are
/// ambient room tone. If the channel were near-continuous speech, the 10th-percentile floor
/// would climb into speech energy and the adaptive threshold could under-detect. This is a
/// documented precondition of the estimator, not a defect.
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
    // Use the actual frame duration (from the integer frameSize) for time conversion so that
    // times stay sample-accurate on odd rates where round(frameSec*sampleRate) != frameSec*sampleRate.
    // At 16 kHz / 30 ms this is exactly 480 samples = 0.03 s, so behavior is unchanged there.
    let actualFrameSec = TimeInterval(frameSize) / TimeInterval(sampleRate)
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
    let minSilenceFrames = Int((minSilenceSec / actualFrameSec).rounded())
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
        let start = TimeInterval(run.first) * actualFrameSec
        let end = min(TimeInterval(run.last + 1) * actualFrameSec, totalDuration)
        if end - start >= minSpeechSec {
            intervals.append(SpeechInterval(start: start, end: end))
        }
    }

    // 6 & 7. Already sorted by construction (runs are built left-to-right).
    return intervals
}

/// Runs `detectSpeechIntervals` over `samples` in fixed `chunkSeconds` chunks, shifts each chunk's
/// intervals into global time, concatenates, and boundary-merges with `mergeAdjacentSpeechIntervals`.
///
/// This is the pure/batch equivalent of `MicVoiceActivityChunker`'s finalize logic: the chunker
/// keeps its incremental `add()`/`removeFirst` mechanism for bounded memory, but the per-chunk
/// offset + boundary-merge math lives here so it is unit-testable and shared with the streaming path.
///
/// Two accepted boundary behaviors (same as the streaming chunker, by construction):
///   (a) `minSpeechSec` is applied *per chunk* before the global merge, so a sub-`minSpeechSec`
///       speech run split exactly across a chunk boundary can be dropped on both sides. Accepted as
///       boundary-local: full-length runs split at a boundary are still stitched by the merge.
///   (b) The noise floor is estimated *per chunk* (local adaptation to room-tone drift over a long
///       meeting), not once globally. Accepted: adjacent chunks may pick slightly different floors.
///
/// - Returns: speech intervals in global seconds, sorted, boundary-merged. Empty input → `[]`.
public func detectSpeechIntervalsChunked(
    _ samples: [Float],
    sampleRate: Int,
    chunkSeconds: Double = 60,
    frameSec: TimeInterval = 0.03,
    minSpeechSec: TimeInterval = 0.20,
    minSilenceSec: TimeInterval = 0.20,
    absoluteFloor: Float = 0.005,
    noiseMultiplier: Float = 3.0
) -> [SpeechInterval] {
    guard sampleRate > 0, chunkSeconds > 0, !samples.isEmpty else { return [] }
    let chunkSize = max(1, Int(chunkSeconds * Double(sampleRate)))

    var accumulated: [SpeechInterval] = []
    var processedSamples = 0
    while processedSamples < samples.count {
        let end = min(processedSamples + chunkSize, samples.count)
        let chunk = Array(samples[processedSamples..<end])
        let offset = Double(processedSamples) / Double(sampleRate)
        let speech = detectSpeechIntervals(
            samples: chunk,
            sampleRate: sampleRate,
            frameSec: frameSec,
            minSpeechSec: minSpeechSec,
            minSilenceSec: minSilenceSec,
            absoluteFloor: absoluteFloor,
            noiseMultiplier: noiseMultiplier
        )
        accumulated.append(contentsOf: speech.map {
            SpeechInterval(start: $0.start + offset, end: $0.end + offset)
        })
        processedSamples = end
    }
    return mergeAdjacentSpeechIntervals(accumulated, minSilenceSec: minSilenceSec)
}

/// Merges consecutive speech intervals whose silent gap is smaller than `minSilenceSec`.
/// Used to stitch a speech run that was split across processing-chunk boundaries back together.
/// Assumes input is sorted by start; output is sorted, non-overlapping, gap>=minSilenceSec between entries.
public func mergeAdjacentSpeechIntervals(_ intervals: [SpeechInterval], minSilenceSec: TimeInterval) -> [SpeechInterval] {
    guard var current = intervals.first else { return [] }
    var out: [SpeechInterval] = []
    for next in intervals.dropFirst() {
        if next.start - current.end < minSilenceSec {
            current = SpeechInterval(start: current.start, end: max(current.end, next.end))
        } else {
            out.append(current)
            current = next
        }
    }
    out.append(current)
    return out
}
