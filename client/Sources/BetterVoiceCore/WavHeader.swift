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
public func makeWavHeader(sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16, dataSize: UInt32) -> Data {
    let blockAlign = channels * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)

    var header = Data(capacity: 44)
    header.append(contentsOf: "RIFF".utf8)
    header.appendLE(UInt32(36) + dataSize)
    header.append(contentsOf: "WAVE".utf8)
    header.append(contentsOf: "fmt ".utf8)
    header.appendLE(UInt32(16))          // PCM fmt chunk length
    header.appendLE(UInt16(1))           // audio format = PCM
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
