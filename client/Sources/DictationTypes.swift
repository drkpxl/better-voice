import Foundation

/// The dictation result type, handed from `VoiceModule` to `VoicePipeline`.
///
/// Previously declared in `VoiceSession.swift` alongside Apple's streaming recognizer, and it carried
/// two more fields that described that recognizer rather than a result: `words: [WordInfo]`, Apple's
/// per-word confidence and alternatives, and `audioPath`, pointing at the WAV dictation used to write
/// before it transcribed from memory. Both were dead — Parakeet reports no per-word confidence
/// (`WordTiming` has none, and `ASRResult.confidence` is one utterance-level figure that would be
/// inventing precision if spread across words), and there is no file to point at. They were kept on
/// the theory that `voice-history.jsonl` needed them to stay decodable; nothing decodes that file.
struct TranscriptionResult {
    let fullText: String
    let timestamp: Date
}
