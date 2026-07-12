import AppKit
import SwiftUI
import WebKit

/// SwiftUI wrapper around the bundled CodeMirror 6 editor (`client/editor/`, built to
/// `Bundle.module`'s `editor.html`). Loaded once via `loadHTMLString(_:baseURL: nil)` — no
/// network access, single self-contained HTML file.
///
/// `text`/`revision` follow the plan's "revision token" rule: `updateNSView` only pushes `text`
/// into the WebView when `revision` changes (switching meeting/tab), never because `text` itself
/// differs from what's currently loaded — the WebView is the source of truth for in-progress
/// edits, so comparing by value would clobber whatever the user is typing.
struct MarkdownEditorView: NSViewRepresentable {
    /// Document text to (re)load. Only applied when `revision` changes; see the type doc.
    var text: String
    /// Bump this to force a reload of `text` (new meeting, new tab). Do not bump it just
    /// because `text` mirrors the user's in-progress typing.
    var revision: Int
    var isReadOnly: Bool
    /// Lets the SwiftUI parent pull the live text out on demand (e.g. for Save) outside of
    /// this view's normal state-diffing update cycle.
    let controller: MarkdownEditorController
    var onContentEdited: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onContentEdited: onContentEdited)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "bridge")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        // Avoid a flash of the wrong color before the page paints. `drawsBackground = false` is
        // private API on WKWebView; `underPageBackgroundColor` is the public equivalent.
        webView.underPageBackgroundColor = .white

        controller.webView = webView
        context.coordinator.loadedRevision = revision
        context.coordinator.loadedReadOnly = isReadOnly
        context.coordinator.requestSetText(text, on: webView)
        context.coordinator.requestSetReadOnly(isReadOnly, on: webView)

        // .appResources, NOT .module — see AppResources.swift (shipped apps crash on .module).
        if let url = Bundle.appResources.url(forResource: "editor", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            Logger.log("MarkdownEditorView", "editor.html resource not found in Bundle.appResources")
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentEdited = onContentEdited

        if context.coordinator.loadedRevision != revision {
            context.coordinator.loadedRevision = revision
            context.coordinator.requestSetText(text, on: webView)
        }
        if context.coordinator.loadedReadOnly != isReadOnly {
            context.coordinator.loadedReadOnly = isReadOnly
            context.coordinator.requestSetReadOnly(isReadOnly, on: webView)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // WKUserContentController retains its message handlers, which would otherwise keep the
        // Coordinator (and the onContentEdited closure it holds) alive past this view's lifetime.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        webView.navigationDelegate = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onContentEdited: () -> Void
        var loadedRevision = -1
        var loadedReadOnly = true

        private var isReady = false
        private var pendingText: String?
        private var pendingReadOnly = true

        init(onContentEdited: @escaping () -> Void) {
            self.onContentEdited = onContentEdited
        }

        func requestSetText(_ text: String, on webView: WKWebView) {
            pendingText = text
            guard isReady else { return }
            applySetText(text, on: webView)
        }

        func requestSetReadOnly(_ readOnly: Bool, on webView: WKWebView) {
            pendingReadOnly = readOnly
            guard isReady else { return }
            applySetReadOnly(readOnly, on: webView)
        }

        private func applySetText(_ text: String, on webView: WKWebView) {
            // Never string-interpolate raw text into JS: JSON-encode it so quotes/newlines/HTML
            // in a transcript can't break out of the string literal.
            guard let data = try? JSONEncoder().encode(text),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.editorAPI && window.editorAPI.setText(\(json));")
        }

        private func applySetReadOnly(_ readOnly: Bool, on webView: WKWebView) {
            webView.evaluateJavaScript("window.editorAPI && window.editorAPI.setReadOnly(\(readOnly));")
            // Entering edit mode: the JS side focuses CodeMirror's DOM element, but that's inert
            // unless the WKWebView itself is the AppKit window's first responder — without this,
            // toggling "Edit" leaves keyboard focus wherever it was (e.g. the Edit button itself),
            // so the first keystrokes silently go nowhere and Save never becomes enabled.
            if !readOnly {
                webView.window?.makeFirstResponder(webView)
            }
        }

        // nonisolated + MainActor.assumeIsolated: WKNavigationDelegate/WKScriptMessageHandler
        // callbacks are always delivered on the main thread (WebKit's contract), but declaring
        // these `nonisolated` keeps the conformance valid regardless of whether the SDK's
        // protocol declarations are themselves @MainActor-isolated.
        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                isReady = true
                if let text = pendingText {
                    applySetText(text, on: webView)
                }
                applySetReadOnly(pendingReadOnly, on: webView)
            }
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "bridge" else { return }
            MainActor.assumeIsolated {
                if let body = message.body as? [String: Any], body["event"] as? String == "contentEdited" {
                    onContentEdited()
                }
            }
        }
    }
}

/// Lets a SwiftUI parent (`TextFileEditorRootView`, for the Personal Context / Vocabulary
/// editor windows) pull the editor's live text (e.g. for Save) without threading it through
/// `MarkdownEditorView`'s normal SwiftUI state-diffing update cycle.
@MainActor
final class MarkdownEditorController {
    fileprivate weak var webView: WKWebView?

    /// Reads the current document text from the editor. `nil` if the web view isn't ready yet
    /// (e.g. save attempted before the page finished loading, which the Save button's disabled
    /// state should prevent in practice).
    func getText() async -> String? {
        guard let webView else { return nil }
        // Deliberately the completion-handler API, not the async overload: the async variant's
        // return type is non-optional `Any` and it TRAPS when the script evaluates to null
        // (which this script does whenever editorAPI isn't ready). The handler form surfaces
        // that as a plain nil — and a nil here means Save writes nothing, rather than a crash
        // or an empty file overwriting a transcript.
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.editorAPI ? window.editorAPI.getText() : null;") { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }
}
