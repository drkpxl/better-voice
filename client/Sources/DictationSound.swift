import AppKit

/// Short system sounds that signal dictation start/stop, so the user gets
/// audible feedback in addition to the on-screen waveform indicator.
///
/// Uses built-in macOS sounds from /System/Library/Sounds. "Pop" (a light
/// rising tick) marks the start of recording; "Bottle" (a hollow close) marks
/// the end — two clearly distinguishable cues.
enum DictationSound {
    private static let startSound = NSSound(named: "Pop")
    private static let stopSound = NSSound(named: "Bottle")

    static func playStart() { play(startSound) }
    static func playStop() { play(stopSound) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()   // restart cleanly if it's still playing
        sound.play()
    }
}
