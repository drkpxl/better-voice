import SwiftUI
import BetterVoiceCore

/// In-app editor for a single freeform text file (`personal-context.md`, `vocabulary.md`),
/// reusing the CodeMirror editor built for the Meetings browser instead of shelling out to
/// `NSWorkspace.shared.open()` — the "why doesn't this open in our own editor" gap.
///
/// Unlike the Meetings transcript/summary editor these files have no read-only mode (they
/// exist to be edited) and no Cancel concept (there's no multi-field form to discard, just
/// text) — so it's Cmd+S to save explicitly, plus a save-on-close safety net so closing the
/// window never silently drops an edit.
///
/// The file path is resolved lazily (via `fileURL`, evaluated on appear — not captured at view
/// construction) so it always reflects the current `SupportDir` root, matching how `Vocabulary`
/// / `PersonalContext` resolve their URLs.
struct TextFileEditorRootView: View {
    let fileURL: @MainActor () -> URL
    /// Runs synchronously before the first load, so a fresh install's starter template exists
    /// before this view tries to read it. A plain second `.onAppear` on the wrapping view
    /// would race this one — SwiftUI doesn't guarantee firing order between them.
    var ensureCreated: @MainActor () -> Void = {}

    @State private var loadedText = ""
    @State private var revision = 0
    @State private var isDirty = false
    @State private var loadFailed = false
    @State private var controller = MarkdownEditorController()

    var body: some View {
        VStack(spacing: 0) {
            MarkdownEditorView(
                text: loadedText,
                revision: revision,
                isReadOnly: false,
                controller: controller,
                onContentEdited: { isDirty = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if loadFailed {
                    Text(t("Could not read this file."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(isDirty ? t("Edited") : t("Saved"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Save")) { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
            .padding(8)
        }
        .frame(width: 640, height: 560)
        .tint(Color.brandAccent)
        .onAppear {
            ensureCreated()
            load()
        }
        .onDisappear {
            // Save-on-close: these are freeform notes with no Cancel concept, so losing an
            // edit because the window was closed instead of Cmd+S'd would be a bad surprise.
            if isDirty {
                Task { await save() }
            }
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: fileURL(), encoding: .utf8) else {
            loadFailed = true
            return
        }
        loadedText = text
        revision += 1
        isDirty = false
    }

    private func save() async {
        guard let text = await controller.getText() else { return }
        let url = fileURL()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            isDirty = false
            Logger.log("TextFileEditor", "Saved \(url.lastPathComponent)")
        } catch {
            Logger.log("TextFileEditor", "Save failed for \(url.lastPathComponent): \(error)")
        }
    }
}

/// Personal context editor root, shown by the `Window(id: WindowID.personalContext)` scene.
struct PersonalContextRootView: View {
    var body: some View {
        TextFileEditorRootView(
            fileURL: { PersonalContext.fileURL },
            ensureCreated: { PersonalContext.ensureCreated() }
        )
    }
}

/// Vocabulary editor root, shown by the `Window(id: WindowID.vocabulary)` scene.
struct VocabularyRootView: View {
    var body: some View {
        TextFileEditorRootView(
            fileURL: { SupportDir.vocabularyURL },
            ensureCreated: { Vocabulary.shared.ensureCreated() }
        )
    }
}
