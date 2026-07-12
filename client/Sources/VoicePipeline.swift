import Foundation
import ApplicationServices

/// Voice post-processing pipeline
/// L2: PolishClient semantic polishing (can be disabled)
/// Inject -> persist to history (local debug log)
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

        // L1: Trust Apple's official ordering, no modifications
        let l1Text = rawText

        // L2: Model polishing (skipped when polish.enabled = false)
        let modelText: String
        let polished: String?
        var l2ElapsedMs = 0
        if RuntimeConfig.shared.polishConfig["enabled"] as? Bool == true {
            let tL2 = CFAbsoluteTimeGetCurrent()
            polished = await PolishClient.shared.polish(
                text: l1Text,
                words: transcription.words,
                app: targetApp
            )
            l2ElapsedMs = Int((CFAbsoluteTimeGetCurrent() - tL2) * 1000)

            // Unconditionally record L2's actual behavior: nil / identity / real change
            let kind: String
            if polished == nil { kind = "nil" }
            else if polished == l1Text { kind = "identity" }
            else { kind = "changed" }
            Logger.log("Pipeline", "L2: elapsedMs=\(l2ElapsedMs) kind=\(kind) output=\(polished ?? "<nil>")")

            modelText = polished ?? l1Text
        } else {
            polished = nil
            modelText = l1Text
            Logger.log("Pipeline", "L2: skipped (polish.enabled=false)")
        }

        // Deterministic vocabulary replacements (vocabulary.md): exact spellings guaranteed
        // even when the model misses — and applied even when polish is disabled.
        let finalText = Vocabulary.shared.apply(to: modelText)

        // Inject into the focused app
        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: finalText, to: targetApp, focusTarget: focusTarget)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        // Persist to history (always written, local debug log: paired with audio/*.wav to help debug transcription issues)
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: l2=\(l2ElapsedMs)ms inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }
}
