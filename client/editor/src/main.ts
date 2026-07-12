// Better Voice markdown editor bundle.
//
// A minimal CodeMirror 6 setup (view/state/commands/language/search/lang-markdown +
// @lezer/highlight only — no autocomplete, no closebrackets, no fold gutter: this edits
// meeting notes, not code) with a plain light/dark-text theme, following the shape of
// MarkEdit's CoreEditor build (https://github.com/MarkEdit-app/MarkEdit, MIT) and its
// `styling/builder.ts` one-palette-feeds-theme-and-highlight-style pattern. Credit:
// MarkEdit + CodeMirror (https://codemirror.net, MIT).
//
// Bridge contract with the native WKWebView host (see MarkdownEditorView.swift):
//   Native -> web: window.editorAPI.{setText,getText,setReadOnly}
//   Web -> native: window.webkit.messageHandlers.bridge.postMessage({ event: "contentEdited" })
// The webkit calls are optional-chained so this file also runs standalone in a normal
// browser (no window.webkit) for local development/verification.
import { Compartment, EditorState } from "@codemirror/state";
import {
  EditorView,
  crosshairCursor,
  drawSelection,
  dropCursor,
  highlightActiveLine,
  keymap,
  rectangularSelection,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { HighlightStyle, bracketMatching, indentOnInput, syntaxHighlighting } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { tags } from "@lezer/highlight";

// MARK: - Theme (palette -> EditorView.theme + HighlightStyle; colors from docs/styles.css)

// Plain, out-of-the-box look: dark text on a light/white background, standard system-blue
// accent — not a bespoke brand palette. Matches a default macOS text editor.
const palette = {
  bg: "#ffffff",
  text: "#1a1a1a",
  heading: "#000000",
  accent: "#0068da",
  accent2: "#0068da",
  caret: "#0068da",
  selection: "rgba(0, 104, 218, 0.20)",
  activeLine: "rgba(0, 0, 0, 0.035)",
  codeBg: "#f2f2f2",
  comment: "#6e6e6e",
  border: "#d8d8d8",
} as const;

const fontSans = '-apple-system, BlinkMacSystemFont, sans-serif';
const fontMono = 'ui-monospace, SFMono-Regular, Menlo, monospace';

const theme = EditorView.theme(
  {
    "&": {
      color: palette.text,
      backgroundColor: palette.bg,
      height: "100%",
      fontSize: "15px",
    },
    ".cm-content": {
      fontFamily: fontSans,
      lineHeight: "1.6",
      caretColor: palette.caret,
      padding: "20px 24px",
    },
    ".cm-scroller": { overflow: "auto", fontFamily: fontSans },
    "&.cm-focused .cm-cursor": { borderLeftColor: palette.caret },
    "&.cm-focused .cm-selectionBackground, .cm-selectionBackground": {
      backgroundColor: `${palette.selection} !important`,
    },
    ".cm-activeLine": { backgroundColor: palette.activeLine },
    ".cm-gutters": { display: "none" },
    ".cm-line": { padding: "0 2px" },
  },
  { dark: false }
);

const highlightStyle = HighlightStyle.define([
  { tag: tags.heading1, color: palette.heading, fontWeight: "bold", fontSize: "1.6em" },
  { tag: tags.heading2, color: palette.heading, fontWeight: "bold", fontSize: "1.35em" },
  { tag: tags.heading3, color: palette.heading, fontWeight: "bold", fontSize: "1.15em" },
  { tag: [tags.heading4, tags.heading5, tags.heading6], color: palette.heading, fontWeight: "bold" },
  { tag: tags.strong, color: palette.heading, fontWeight: "bold" },
  { tag: tags.emphasis, fontStyle: "italic" },
  { tag: tags.strikethrough, textDecoration: "line-through" },
  { tag: tags.link, color: palette.accent, textDecoration: "underline" },
  { tag: tags.url, color: palette.accent2 },
  { tag: tags.quote, color: palette.comment, fontStyle: "italic" },
  { tag: tags.monospace, color: palette.text, fontFamily: fontMono, backgroundColor: palette.codeBg },
  { tag: tags.processingInstruction, color: palette.comment },
  { tag: tags.contentSeparator, color: palette.border },
  { tag: tags.list, color: palette.accent2 },
  { tag: tags.comment, color: palette.comment },
]);

// MARK: - Editor setup

const readOnlyCompartment = new Compartment();

function readOnlyExtensions(readOnly: boolean) {
  return [EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly)];
}

let notifyTimer: ReturnType<typeof setTimeout> | undefined;

/// Web -> native dirty notification, debounced 500ms so we don't flood the bridge on every keystroke.
function notifyContentEdited() {
  if (notifyTimer !== undefined) clearTimeout(notifyTimer);
  notifyTimer = setTimeout(() => {
    window.webkit?.messageHandlers?.bridge?.postMessage({ event: "contentEdited" });
  }, 500);
}

const updateListener = EditorView.updateListener.of((update) => {
  if (update.docChanged) notifyContentEdited();
});

let currentReadOnly = false;

function buildExtensions(readOnly: boolean) {
  return [
    history(),
    drawSelection(),
    dropCursor(),
    indentOnInput(),
    bracketMatching(),
    rectangularSelection(),
    crosshairCursor(),
    highlightActiveLine(),
    highlightSelectionMatches(),
    EditorView.lineWrapping,
    markdown({ codeLanguages: languages }),
    syntaxHighlighting(highlightStyle, { fallback: true }),
    theme,
    readOnlyCompartment.of(readOnlyExtensions(readOnly)),
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, indentWithTab]),
    updateListener,
  ];
}

// Standalone test mode: when embedded in the native app, window.webkit is present and the
// Swift side calls setText() right after load; in a plain browser (local verification /
// development) there's no window.webkit, so seed a sample doc to demonstrate the theme.
const sampleMarkdown = `# Weekly Sync — Product Team

- Date: 2026-07-04 09:30
- Duration: 32m 10s

---

**Decision:** ship the Meetings browser behind a flag next sprint.

## Action items

- Wire \`MeetingLibrary\` to the Transcripts/Summaries folders
- Review the editor theme against \`docs/styles.css\`

Try the bridge from the console: \`window.editorAPI.getText()\`.
`;

const initialDoc = window.webkit ? "" : sampleMarkdown;

const view = new EditorView({
  state: EditorState.create({
    doc: initialDoc,
    extensions: buildExtensions(currentReadOnly),
  }),
  parent: document.getElementById("editor")!,
});

// MARK: - Bridge (native -> web)

window.editorAPI = {
  setText(text: string) {
    // A fresh EditorState (not a transaction on the existing one) so undo history resets —
    // switching meetings/tabs shouldn't let Cmd+Z reach into the previous document.
    view.setState(
      EditorState.create({
        doc: text,
        extensions: buildExtensions(currentReadOnly),
      })
    );
  },
  getText() {
    return view.state.doc.toString();
  },
  setReadOnly(readOnly: boolean) {
    currentReadOnly = readOnly;
    view.dispatch({
      effects: readOnlyCompartment.reconfigure(readOnlyExtensions(readOnly)),
    });
    // Toggling into edit mode doesn't hand the document keyboard focus on its own — the DOM's
    // contenteditable div stays unfocused until something explicitly focuses it, so the first
    // keystroke after clicking "Edit" would otherwise go nowhere. Native additionally has to make
    // the WKWebView itself the window's first responder (see MarkdownEditorView.swift).
    if (!readOnly) {
      view.focus();
    }
  },
  // Diagnostic-only: simulates a real keystroke (a CM6 transaction) without needing an actual
  // click + key event, so the edit -> dirty -> bridge chain can be verified headlessly (see
  // BetterVoice2App.swift's --bench-editor). Harmless in production: local trusted HTML only,
  // never reachable from real web content, and native code never calls it outside the bench path.
  __debugInsertText(text: string) {
    view.dispatch({ changes: { from: view.state.doc.length, insert: text } });
  },
};
