# Better Voice editor bundle

A minimal [CodeMirror 6](https://codemirror.net) (MIT) markdown editor, themed to the
Better Voice brand, built with Vite + [vite-plugin-singlefile](https://github.com/richardtallent/vite-plugin-singlefile)
into **one self-contained HTML file** with no external requests — no CDN scripts, no
remote fonts, everything inlined. This lets the Swift app load it entirely offline via
`WKWebView.loadHTMLString(_:baseURL: nil)`.

The dependency list, single-file build shape, and the "one palette feeds `EditorView.theme`
+ `HighlightStyle`" theming pattern in `src/main.ts` follow the recipe used by
[MarkEdit](https://github.com/MarkEdit-app/MarkEdit) (MIT) — credit to MarkEdit and
CodeMirror for the patterns this bundle is built from. We don't vendor MarkEdit's own
built bundle: it isn't committed anywhere (only inside release DMGs), it's wired to a
chunk-loading `WKURLSchemeHandler` and a generated bridge bigger than what we need, its
theme system only accepts pre-registered theme names (so brand colors require rebuilding
it anyway), and it embeds SF Mono webfonts we can't redistribute. Building our own minimal
bundle from the same ingredients is simpler and keeps this repo's editor fully
self-contained.

## Build

```sh
npm install
npm run build
```

This runs `vite build` (producing `dist/index.html`) and then copies it to
`../Sources/Resources/editor.html`, which ships in the app via SwiftPM's
`.process("Resources")` resource processing — CI never needs Node.

**Never hand-edit `../Sources/Resources/editor.html` — it is generated. Edit
`src/main.ts` (or `vite.config.ts`) and re-run `npm run build`.**

## Local verification

Since the Swift app can't be built/run everywhere, this bundle is independently
verifiable:

```sh
npm run build
open ../Sources/Resources/editor.html   # or dist/index.html
```

Opening it in a plain browser (no `window.webkit`) seeds a sample meeting-summary
markdown document so the theme is visible immediately. From the browser console:

```js
window.editorAPI.getText()
window.editorAPI.setText("# Hello\n\nworld")
window.editorAPI.setReadOnly(true)
```

## Bridge contract

- Native -> web: `window.editorAPI.setText(text)` / `getText()` / `setReadOnly(bool)`.
- Web -> native: on document changes, debounced 500ms,
  `window.webkit.messageHandlers.bridge.postMessage({ event: "contentEdited" })`
  (optional-chained, so this also works standalone with no `window.webkit`).

## Dev

```sh
npm run dev
```

Runs the Vite dev server (multi-file, not single-file) for faster iteration on the
theme/editor; always verify with `npm run build` before committing.
