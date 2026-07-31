import Foundation
import ApplicationServices
import BetterVoiceCore

/// Voice post-processing pipeline
/// Vocabulary replacement -> inject -> persist to history (local debug log)
///
/// The LLM polish stage is gone. It was measured against a hand-corrected reference on real dictation
/// (`bench/results/2026-07-30-results.json`): on Apple's transcript it bought 0.5 WER points, and on
/// the Apple on-device backend this app actually shipped, **exactly zero** — while costing ~4s of the
/// ~5s a user waited before text appeared. The engine choice dominates it by 5-19x, which is why the
/// effort moved to the engine instead. Deterministic vocabulary replacement stays: it is the jargon
/// channel, it is exact word-boundary only, and it costs nothing.
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?,
        focusTarget: AXUIElement? = nil
    ) async {
        let tStart = CFAbsoluteTimeGetCurrent()
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // Strip discourse fillers deterministically -- "um", "uh", and sentence-opening "so"/"well".
        // This is the one job the deleted LLM stage was genuinely doing that nothing else replaced:
        // Parakeet already emits punctuation and capitalization, and jargon goes through the
        // vocabulary channel below, but nothing else removes an "um". A model was never needed to.
        //
        // Runs BEFORE vocabulary so a replacement's output can never be mistaken for a filler.
        let stripped: String
        if RuntimeConfig.shared.stripFillers {
            let result = FillerStripper.strip(rawText)
            stripped = result.text
            if !result.removed.isEmpty {
                Logger.log("Pipeline", "Fillers removed (\(result.removed.count)): \(result.removed.joined(separator: " "))")
            }
        } else {
            stripped = rawText
        }

        // A stripper that emptied the text has removed everything the user said, which means the
        // dictation was nothing but fillers. Fall back to the raw text rather than injecting nothing --
        // silently pasting an empty string is indistinguishable from the hotkey not working.
        let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawText : stripped

        // Deterministic vocabulary replacements (vocabulary.md): exact spellings guaranteed,
        // with no model in the path to invent a substitution.
        let finalText = Vocabulary.shared.apply(to: cleaned)

        // Inject into the focused app
        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: finalText, to: targetApp, focusTarget: focusTarget)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        // Always written, as a local debug log: `rawText` vs `finalText` is what the filler stripper
        // and vocabulary changed.
        history.save(transcription: transcription, finalText: finalText, app: targetApp)

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }
}
