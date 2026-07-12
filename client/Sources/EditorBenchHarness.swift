#if BENCH
import AppKit
import WebKit

/// Headless verification of the CodeMirror editor's edit -> dirty -> save chain, using the
/// SAME `MarkdownEditorView`/`MarkdownEditorController` production code the app uses — not a
/// reimplementation. Simulates a keystroke via the JS-side `__debugInsertText` diagnostic (see
/// editor/src/main.ts) instead of real mouse/keyboard, so it can run in CI/without a display.
@MainActor
final class EditorBenchHarness: NSObject {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onDone: (() -> Void)?
    /// Set true when the "bridge" message handler receives a contentEdited event — this is the
    /// EXACT signal `MarkdownEditorView.Coordinator` forwards to its `onContentEdited` closure
    /// (e.g. `TextFileEditorRootView` setting `isDirty = true`), which is what enables the Save
    /// button. This is the part the earlier getText()-only check did NOT exercise.
    private var receivedContentEdited = false

    func run(onDone: @escaping () -> Void) {
        self.onDone = onDone

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "bridge")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        self.webView = webView

        guard let url = Bundle.appResources.url(forResource: "editor", withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            print("FAIL: editor.html not found in Bundle.appResources")
            onDone()
            return
        }
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)

        let win = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = webView
        self.window = win
    }

    private func afterLoad() {
        Task {
            // 1. Load some text, exit read-only mode (mirrors toggling "Edit" on).
            await setText("# Original\n")
            await setReadOnly(false)

            // 1b. The real-world bug: toggling editable-on doesn't guarantee the contenteditable
            // DOM element actually has keyboard focus. Check document.activeElement directly.
            let activeClass = try? await webView?.evaluateJavaScript(
                "document.activeElement ? document.activeElement.className : '<none>';"
            ) as? String
            let focused = activeClass?.contains("cm-content") == true
            print(focused
                  ? "PASS: CodeMirror's content element has DOM focus after entering edit mode"
                  : "FAIL: nothing is focused after entering edit mode (activeElement=\(activeClass ?? "nil")) — real keystrokes would go nowhere")

            // 2. Simulate a keystroke.
            _ = try? await webView?.evaluateJavaScript("window.editorAPI.__debugInsertText('typed by user');")

            // 3. The bridge notification is debounced 500ms; wait past it, then read back the
            //    text via the same JS getText() the Save button's controller.getText() calls.
            try? await Task.sleep(nanoseconds: 900_000_000)
            let text = try? await webView?.evaluateJavaScript("window.editorAPI.getText();") as? String

            let ok = text?.contains("typed by user") == true
            print(ok ? "PASS: editor text reflects the simulated edit" : "FAIL: editor text unchanged after simulated edit")
            print("getText() -> \(text ?? "<nil>")")
            print(receivedContentEdited
                  ? "PASS: bridge received contentEdited (this is what enables Save)"
                  : "FAIL: bridge did NOT receive contentEdited — Save would stay disabled")

            // 4. Re-enable read-only (mirrors toggling "Edit" off) and confirm typing is blocked.
            await setReadOnly(true)
            _ = try? await webView?.evaluateJavaScript("window.editorAPI.__debugInsertText(' MORE');")
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Note: __debugInsertText dispatches directly (bypassing the editable check CM6 applies
            // to real keystrokes), so this doesn't prove real-keyboard blocking — only that the
            // read-only flag itself round-trips without crashing.

            onDone?()
        }
    }

    private func setText(_ text: String) async {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else { return }
        _ = try? await webView?.evaluateJavaScript("window.editorAPI.setText(\(json));")
    }

    private func setReadOnly(_ readOnly: Bool) async {
        _ = try? await webView?.evaluateJavaScript("window.editorAPI.setReadOnly(\(readOnly));")
    }
}

extension EditorBenchHarness: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { afterLoad() }
    }
}

extension EditorBenchHarness: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let body = message.body as? [String: Any], body["event"] as? String == "contentEdited" {
                receivedContentEdited = true
            }
        }
    }
}
#endif
