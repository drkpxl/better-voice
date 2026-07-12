// Copies the Vite single-file build output to the SwiftPM app resource location.
// Run automatically by `npm run build` (see package.json). Never hand-edit the
// destination file — it is generated.
import { copyFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const editorDir = dirname(dirname(fileURLToPath(import.meta.url)));
const src = join(editorDir, "dist", "index.html");
const destDir = join(editorDir, "..", "Sources", "Resources");
const dest = join(destDir, "editor.html");

mkdirSync(destDir, { recursive: true });
copyFileSync(src, dest);
console.log(`Copied ${src} -> ${dest}`);
