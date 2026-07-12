import XCTest
@testable import BetterVoiceCore

/// Contract for `AudioSilenceCheck`/`RunningRMS` — Bug 2's "empty/silent capture must not throw a
/// raw import error" detection. `MeetingCoordinator.stopMeeting()` uses these to decide whether a
/// just-finalized meeting WAV is worth handing to `ImportPipeline` at all.
final class AudioSilenceTests: XCTestCase {

    // MARK: - isEffectivelySilent

    func test_zeroFramesIsSilentRegardlessOfRMS() {
        XCTAssertTrue(AudioSilenceCheck.isEffectivelySilent(frameCount: 0, rms: 1.0))
    }

    func test_lowRMSWithFramesIsSilent() {
        XCTAssertTrue(AudioSilenceCheck.isEffectivelySilent(frameCount: 48000, rms: 0.0001))
    }

    func test_normalSpeechLevelIsNotSilent() {
        XCTAssertFalse(AudioSilenceCheck.isEffectivelySilent(frameCount: 48000, rms: 0.05))
    }

    func test_rmsExactlyAtThresholdIsNotSilent() {
        // "Below" is strict: rms == threshold is the first value that counts as real signal.
        let threshold: Float = 0.001
        XCTAssertFalse(AudioSilenceCheck.isEffectivelySilent(frameCount: 100, rms: threshold, rmsThreshold: threshold))
    }

    func test_rmsJustAboveThresholdIsNotSilent() {
        let threshold: Float = 0.001
        XCTAssertFalse(AudioSilenceCheck.isEffectivelySilent(frameCount: 100, rms: threshold + 0.0001, rmsThreshold: threshold))
    }

    func test_customThresholdIsRespected() {
        XCTAssertTrue(AudioSilenceCheck.isEffectivelySilent(frameCount: 100, rms: 0.05, rmsThreshold: 0.1))
        XCTAssertFalse(AudioSilenceCheck.isEffectivelySilent(frameCount: 100, rms: 0.05, rmsThreshold: 0.01))
    }

    // MARK: - RunningRMS

    func test_runningRMSStartsAtZero() {
        let running = RunningRMS()
        XCTAssertEqual(running.rms, 0)
        XCTAssertEqual(running.sampleCount, 0)
    }

    func test_runningRMSOfAllZerosIsZero() {
        var running = RunningRMS()
        running.add([0, 0, 0, 0])
        XCTAssertEqual(running.rms, 0)
        XCTAssertEqual(running.sampleCount, 4)
    }

    func test_runningRMSOfConstantAmplitude() {
        var running = RunningRMS()
        running.add([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(running.rms, 0.5, accuracy: 0.0001)
    }

    func test_runningRMSMatchesKnownValue() {
        // RMS of [1, -1] is 1.0 (mean square = 1, sqrt = 1).
        var running = RunningRMS()
        running.add([1, -1])
        XCTAssertEqual(running.rms, 1.0, accuracy: 0.0001)
    }

    func test_runningRMSIsConsistentAcrossChunkedAdds() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]

        var singlePass = RunningRMS()
        singlePass.add(samples)

        var chunked = RunningRMS()
        chunked.add(Array(samples[0..<3]))
        chunked.add(Array(samples[3..<8]))

        XCTAssertEqual(singlePass.rms, chunked.rms, accuracy: 0.0001)
        XCTAssertEqual(chunked.sampleCount, samples.count)
    }
}
