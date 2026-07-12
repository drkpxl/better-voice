import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

// Single-file build: CodeMirror + our theme/bridge inlined into one HTML file with no
// external requests, no code-splitting. Mirrors MarkEdit's CoreEditor/src/@light build
// shape (their reference for a minimal, dependency-free CodeMirror bundle). The output
// (dist/index.html) is copied to ../Sources/Resources/editor.html by the build script
// and shipped via SwiftPM's `.process("Resources")` — no network access at runtime.
export default defineConfig({
  build: {
    target: "es2022",
    cssCodeSplit: false,
    assetsInlineLimit: 100_000_000,
  },
  plugins: [viteSingleFile()],
});
