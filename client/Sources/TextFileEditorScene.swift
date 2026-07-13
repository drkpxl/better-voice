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
    var body: some View { VocabularyFormView() }
}

// MARK: - Structured vocabulary form

/// Structured editor for `vocabulary.md`, replacing a raw-markdown `TextFileEditorRootView`
/// so a non-technical user can't produce an unparseable file. Two plain-language sections
/// mirror `Vocabulary`'s two entry kinds (`terms` / `replacements`); every add, remove, or
/// committed edit persists immediately via `Vocabulary.shared.update(terms:replacements:)`,
/// which itself no-ops (and never rewrites the file) when nothing actually changed.
struct VocabularyFormView: View {
    /// `id` lets `ForEach` track a row across edits/deletes even though `TextField` bindings
    /// mutate the row's text in place — without a stable identity, deleting a middle row would
    /// let SwiftUI reuse/reshuffle the wrong `TextField`'s editing state.
    private struct TermRow: Identifiable {
        let id = UUID()
        var text: String
    }

    private struct FixRow: Identifiable {
        let id = UUID()
        var from: String
        var to: String
    }

    @State private var termRows: [TermRow] = []
    @State private var fixRows: [FixRow] = []

    var body: some View {
        Form {
            Section {
                ForEach($termRows) { $row in
                    HStack {
                        TextField(t("Spelling"), text: $row.text)
                            .onSubmit { save() }
                        removeButton { removeTerm(row.id) }
                    }
                }
                Button(t("Add spelling")) { addTerm() }
            } header: {
                Text(t("Preferred spellings"))
            } footer: {
                Text(t("Names, products, or acronyms you want spelled a certain way."))
            }

            Section {
                ForEach($fixRows) { $row in
                    HStack {
                        TextField(t("When you hear…"), text: $row.from)
                            .onSubmit { save() }
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField(t("Write…"), text: $row.to)
                            .onSubmit { save() }
                        removeButton { removeFix(row.id) }
                    }
                }
                Button(t("Add fix")) { addFix() }
            } header: {
                Text(t("Sound-alike fixes"))
            } footer: {
                Text(t("When speech-to-text mishears a word, always swap it."))
            }
        }
        .formStyle(.grouped)
        .tint(Color.brandAccent)
        .frame(width: 640, height: 560)
        .onAppear {
            Vocabulary.shared.ensureCreated()
            termRows = Vocabulary.shared.terms.map { TermRow(text: $0) }
            fixRows = Vocabulary.shared.replacements.map { FixRow(from: $0.from, to: $0.to) }
        }
        // Belt-and-suspenders alongside `.onSubmit`: catches edits committed by clicking away
        // or closing the window rather than pressing Return, so nothing typed is ever lost.
        .onChange(of: termRows.map(\.text)) { save() }
        .onChange(of: fixRows.map { [$0.from, $0.to] }) { save() }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("Remove"))
    }

    private func addTerm() {
        termRows.append(TermRow(text: ""))
        save()
    }

    private func removeTerm(_ id: UUID) {
        termRows.removeAll { $0.id == id }
        save()
    }

    private func addFix() {
        fixRows.append(FixRow(from: "", to: ""))
        save()
    }

    private func removeFix(_ id: UUID) {
        fixRows.removeAll { $0.id == id }
        save()
    }

    /// Maps rows to the trimmed/non-empty shapes `Vocabulary.update` expects and persists.
    /// Blank spelling rows and half-filled fixes (either side empty after trimming) are
    /// dropped here rather than validated at input time — the form always shows exactly what
    /// the user typed, including a mid-edit blank row.
    private func save() {
        let terms = termRows
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let replacements = fixRows.compactMap { row -> VocabularyReplacement? in
            let from = row.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = row.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return VocabularyReplacement(from: from, to: to)
        }
        Vocabulary.shared.update(terms: terms, replacements: replacements)
    }
}
