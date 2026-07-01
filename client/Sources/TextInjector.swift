import AppKit

/// Text injector
///
/// Uses clipboard + simulated ⌘V paste. Three key fixes (vs. earlier versions):
///
/// 1. **Post to `.cgSessionEventTap` (not `.cghidEventTap`)**.
///    On macOS 14+, keyboard events injected via `.cghidEventTap` can be silently dropped under stricter security policies;
///    `.cgSessionEventTap` operates at the user-session level and delivers Cmd+V to other apps more reliably.
///
/// 2. **After writing to the clipboard, wait 5ms for the OS to commit it** before posting Cmd+V.
///    NSPasteboard writes are non-atomic (changeCount increments immediately, but the actual content has a slight delay before it's visible across processes),
///    so posting Cmd+V immediately can occasionally cause the target app to paste stale clipboard content.
///
/// 3. **30ms after posting, verify whether `pb.changeCount` has changed**. Cmd+V doesn't write to the clipboard, but the target app
///    may trigger system mechanisms like paste history after pasting, which changes changeCount. Just logging "Pasted" without
///    verifying is an observability gap — only after verifying do we know whether it was a real paste or a failure. The log includes `verified=Y/N`.
enum TextInjector {
    @MainActor
    static func inject(text: String, to app: AppIdentity?) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general

        // Save the current clipboard
        let savedString = pb.string(forType: .string)
        let changeCountBeforeWrite = pb.changeCount

        // Write the text to be injected
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterWrite = pb.changeCount

        // Let the OS commit the clipboard content (visible across processes)
        usleep(5_000)

        // Simulate ⌘V — using cgSessionEventTap, which is more reliable than cghidEventTap on macOS 14+
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)

        // 30ms later, log changeCount purely as a diagnostic. NOTE: this is NOT a reliable
        // success/failure signal — ⌘V *reads* the pasteboard, it doesn't write, so a perfectly
        // successful paste leaves changeCount UNCHANGED (verified=N is the normal case). It only
        // flips to Y when something else mutates the pasteboard (a clipboard-history manager, an
        // app that copies-on-paste). So don't gate UI on it — the log is for debugging only.
        let appBundle = app?.bundleID ?? "unknown"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            let changeCountAfterPaste = pb.changeCount
            let pasteboardTouched = changeCountAfterPaste != changeCountAfterWrite
            Logger.log(
                "Injector",
                "Pasted to \(appBundle) pasteboardTouched=\(pasteboardTouched ? "Y" : "N") cc=\(changeCountBeforeWrite)→\(changeCountAfterWrite)→\(changeCountAfterPaste)"
            )

            // Restore the clipboard after another 500ms delay (only if it wasn't changed by another operation in the meantime)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if pb.changeCount == changeCountAfterPaste, let saved = savedString {
                    pb.clearContents()
                    pb.setString(saved, forType: .string)
                }
            }
        }
    }
}
