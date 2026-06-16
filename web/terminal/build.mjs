// Builds the blit terminal web client into a single self-contained bundle that
// WKWebView can load via loadFileURL.
//
// Output:
//   dist/bundle.js   — esbuild IIFE bundle (React + @blit-sh/* + inlined WASM)
//   dist/index.html  — HTML shell with the bundle inlined as a <script>, so the
//                      whole app is ONE file with no sidecar fetches.
import { build } from "esbuild";
import { readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = dirname(fileURLToPath(import.meta.url));
const distDir = join(root, "dist");

await rm(distDir, { recursive: true, force: true });
await mkdir(distDir, { recursive: true });

const result = await build({
  entryPoints: [join(root, "src/index.tsx")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari16"],
  jsx: "automatic",
  minify: true,
  sourcemap: false,
  outfile: join(distDir, "bundle.js"),
  loader: {
    // Inline the blit WASM as raw bytes so the bundle is self-contained.
    ".wasm": "binary",
  },
  define: {
    "process.env.NODE_ENV": '"production"',
  },
  logLevel: "info",
  metafile: true,
});

// Inline the bundle into index.html for a single loadable file.
const html = await readFile(join(root, "index.html"), "utf8");
const bundleJs = await readFile(join(distDir, "bundle.js"), "utf8");

const inlined = html.replace(
  /<script[^>]*src="\.\/dist\/bundle\.js"[^>]*><\/script>/,
  () => `<script>\n${bundleJs}\n</script>`,
);

if (inlined === html) {
  throw new Error(
    "build: failed to find the bundle <script> placeholder in index.html",
  );
}

await writeFile(join(distDir, "index.html"), inlined, "utf8");

// Report which @blit-sh exports actually got resolved (sanity for Phase 5).
const inputs = Object.keys(result.metafile.inputs);
const blitInputs = inputs.filter((p) => p.includes("@blit-sh"));
console.log(`\nBundled ${blitInputs.length} @blit-sh module files.`);
console.log("Wrote dist/bundle.js and dist/index.html (self-contained).");
