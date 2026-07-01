import XCTest
@testable import BetterVoiceCore

final class WavHeaderTests: XCTestCase {
    // Reads a little-endian UInt32 at byte offset.
    private func u32(_ d: Data, _ off: Int) -> UInt32 {
        UInt32(d[off]) | (UInt32(d[off + 1]) << 8) | (UInt32(d[off + 2]) << 16) | (UInt32(d[off + 3]) << 24)
    }
    private func u16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
    }
    private func ascii(_ d: Data, _ off: Int, _ len: Int) -> String {
        String(bytes: d[off..<(off + len)], encoding: .ascii)!
    }

    func test_headerIsCanonical44BytePCM() {
        // 16kHz mono 16-bit, 1000 bytes of audio data.
        let h = makeWavHeader(sampleRate: 16000, channels: 1, bitsPerSample: 16, dataSize: 1000)

        XCTAssertEqual(h.count, 44)
        XCTAssertEqual(ascii(h, 0, 4), "RIFF")
        XCTAssertEqual(u32(h, 4), 36 + 1000)          // chunk size
        XCTAssertEqual(ascii(h, 8, 4), "WAVE")
        XCTAssertEqual(ascii(h, 12, 4), "fmt ")
        XCTAssertEqual(u32(h, 16), 16)                // fmt chunk length
        XCTAssertEqual(u16(h, 20), 1)                 // PCM
        XCTAssertEqual(u16(h, 22), 1)                 // channels
        XCTAssertEqual(u32(h, 24), 16000)             // sample rate
        XCTAssertEqual(u32(h, 28), 16000 * 2)         // byte rate = sr * blockAlign
        XCTAssertEqual(u16(h, 32), 2)                 // block align = channels * bytes/sample
        XCTAssertEqual(u16(h, 34), 16)                // bits per sample
        XCTAssertEqual(ascii(h, 36, 4), "data")
        XCTAssertEqual(u32(h, 40), 1000)              // data size
    }

    func test_stereo24bitDerivedFields() {
        let h = makeWavHeader(sampleRate: 48000, channels: 2, bitsPerSample: 24, dataSize: 0)
        XCTAssertEqual(u16(h, 32), 6)                 // blockAlign = 2 * (24/8)
        XCTAssertEqual(u32(h, 28), 48000 * 6)         // byteRate
        XCTAssertEqual(u32(h, 4), 36)                 // 36 + 0
    }
}
