import AppKit

/// Short system sounds that signal dictation start/stop, so the user gets
/// audible feedback in addition to the on-screen waveform indicator.
///
/// Uses built-in macOS sounds from /System/Library/Sounds. "Pop" (a light
/// rising tick) marks the start of recording; "Bottle" (a hollow close) marks
/// the end — two clearly distinguishable cues. "Tink" marks a cancelled dictation (Esc), so it
/// never sounds like a successful stop.
enum DictationSound {
    private static let startSound = NSSound(named: "Pop")
    private static let stopSound = NSSound(named: "Bottle")
    private static let cancelSound = NSSound(named: "Tink")

    static func playStart() { play(startSound) }
    static func playStop() { play(stopSound) }
    static func playCancel() { play(cancelSound) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()   // restart cleanly if it's still playing
        sound.play()
    }
}
