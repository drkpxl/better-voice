import Foundation

/// Builds a canonical 44-byte PCM WAV header (RIFF/WAVE, `fmt ` + `data` chunks).
///
/// Pure byte logic, extracted so the two capture paths (`SystemAudioCapturer` and
/// `MeetingCaptureDelegate`) share one implementation and it can be unit-tested without
/// audio hardware. Callers write a 44-byte placeholder up front, stream PCM frames, then
/// seek to 0 and overwrite with this header once `dataSize` (total audio bytes) is known.
///
/// - Parameters:
///   - sampleRate: frames per second (e.g. 16000).
///   - channels: interleaved channel count.
///   - bitsPerSample: bit depth (e.g. 16).
///   - dataSize: total number of PCM audio bytes that follow the header.
///   - isFloat: which `fmt ` format tag to write — `false` for tag `1`
///     (`WAVE_FORMAT_PCM`, fixed-point integer samples, e.g. 16-bit dictation audio) or `true`
///     for tag `3` (`WAVE_FORMAT_IEEE_FLOAT`). This is NOT cosmetic: a reader determines how to
///     interpret each sample's bytes from this tag alone. Core Audio process taps deliver
///     INTERLEAVED FLOAT32 samples (see `SystemAudioCapturer`'s doc comments) — writing those
///     bytes under tag `1` makes `AVAudioFile` decode them as raw fixed-point integers instead
///     of IEEE floats, silently corrupting every sample into noise despite a byte-for-byte
///     "valid" WAV file (verified empirically: tag `1` + 32-bit float bytes round-trips through
///     `AVAudioFile` as garbage, tag `3` round-trips exactly). No default — every call site must
///     say which its buffer actually is.
public func makeWavHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataSize: UInt32, isFloat: Bool) -> Data {
    let blockAlign = channels * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    let formatTag: UInt16 = isFloat ? 3 : 1   // WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM

    var header = Data(capacity: 44)
    header.append(contentsOf: "RIFF".utf8)
    header.appendLE(UInt32(36) + dataSize)
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.appendLE(UInt32(16))          // PCM fmt chunk length
    header.appendLE(formatTag)
    header.appendLE(channels)
    header.appendLE(sampleRate)
    header.appendLE(byteRate)
    header.appendLE(blockAlign)
    header.appendLE(bitsPerSample)
    header.append(contentsOf: "data".utf8)
    header.appendLE(dataSize)
    return header
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
