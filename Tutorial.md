# Rendering Repository Diffs

This walkthrough renders diffs from a local git repository using the OCaml backend and JS/SVG viewer. It uses `getsentry/sentry-cocoa` as an example repository, but the same commands work for any local checkout.

The current semantic adapters cover Swift, C, C++, and C/C++ headers. Objective-C `.m` and Objective-C++ `.mm` files will still appear at the file level in the diff scene, but they do not yet get syntax-level semantic symbols.

## 1. Prepare a Repository

Use any local git checkout. For example, clone `sentry-cocoa` somewhere outside this project:

```bash
cd /Users/jcarlson/Projects
git clone https://github.com/getsentry/sentry-cocoa.git
```

Use this project as the renderer/backend:

```bash
cd /Users/jcarlson/Projects/GitVisualizationDiff
opam exec -- dune build
```

Create a scratch output directory:

```bash
mkdir -p /tmp/gvd-render-repo-diffs
```

## Quick Scripted Path

If the repository is already cloned, the helper script performs the same steps and uses `/tmp/gvd-render-repo-diffs` as its default workspace:

```bash
cd /Users/jcarlson/Projects/GitVisualizationDiff
scripts/render-repo-diffs.sh \
  --repo /Users/jcarlson/Projects/sentry-cocoa \
  --base HEAD~1 \
  --target HEAD
```

The script writes:

- `/tmp/gvd-render-repo-diffs/diff.json`
- `/tmp/gvd-render-repo-diffs/semantic-files.txt`
- `/tmp/gvd-render-repo-diffs/semantics.json`, when there are recognized files
- `/tmp/gvd-render-repo-diffs/scene.json`
- `/tmp/gvd-render-repo-diffs/scene-file-level.json`

It starts the viewer on `http://127.0.0.1:4173` unless `--no-serve` is passed.
The viewer defaults to dark mode; if your browser has a previous light-mode preference saved, use the theme toggle or open `/tmp/gvd-render-repo-diffs/open-dark-viewer.html` once.

## 2. Choose Revisions

For a first render, point `REPO` at the checkout you want to inspect and compare the current checkout to its parent:

```bash
export REPO=/Users/jcarlson/Projects/sentry-cocoa
export BASE=HEAD~1
export TARGET=HEAD
```

For a larger range, use any valid git revisions:

```bash
export BASE=main
export TARGET=HEAD
```

## 3. Extract the Git Diff

From `GitVisualizationDiff`:

```bash
opam exec -- dune exec git-visualization-diff -- extract-diff \
  --repo "$REPO" \
  --base "$BASE" \
  --target "$TARGET" \
  --out /tmp/gvd-render-repo-diffs/diff.json
```

This produces file-level diff data, hunks, line changes, statuses, rename metadata, and summary metrics.

## 4. Pick Files for Semantic Extraction

The semantic extractor needs a list of repo-relative source files. Start with files changed between the same revisions and filter to languages currently backed by tree-sitter:

```bash
cd "$REPO"
git diff --name-only --diff-filter=ACMRT "$BASE" "$TARGET" \
  | grep -E '\.(swift|c|h|cc|cpp|cxx|hh|hpp)$' \
  > /tmp/gvd-render-repo-diffs/semantic-files.txt
```

Notes:

- `--diff-filter=ACMRT` excludes deleted files because the current extractor reads files from the working tree.
- Renamed files are fine; the semantic join can match old paths to current file nodes.
- Objective-C `.m` and Objective-C++ `.mm` are intentionally excluded for now because there is not yet an adapter for them.

If the file list is empty, choose a wider revision range or manually add one or more Swift/C/C++ files.

## 5. Extract Semantics

Return to this project and run:

```bash
cd /Users/jcarlson/Projects/GitVisualizationDiff
opam exec -- dune exec git-visualization-diff -- extract-semantics \
  --repo "$REPO" \
  $(cat /tmp/gvd-render-repo-diffs/semantic-files.txt) \
  --out /tmp/gvd-render-repo-diffs/semantics.json
```

The output should contain `files` entries for recognized Swift/C/C++ files and symbol entries for declarations such as classes, structs, enums, functions, methods, properties, templates, and generic declarations.

## 6. Build Scene JSON

Build renderer-ready scene JSON:

```bash
opam exec -- dune exec git-visualization-diff -- build-scene \
  --diff /tmp/gvd-render-repo-diffs/diff.json \
  --semantic /tmp/gvd-render-repo-diffs/semantics.json \
  --out /tmp/gvd-render-repo-diffs/scene.json
```

If you want a file-level scene without semantic symbols:

```bash
opam exec -- dune exec git-visualization-diff -- build-scene \
  --diff /tmp/gvd-render-repo-diffs/diff.json \
  --out /tmp/gvd-render-repo-diffs/scene-file-level.json
```

## 7. Preview the Scene

Start the viewer:

```bash
node viewer/serve-preview.mjs \
  --scene /tmp/gvd-render-repo-diffs/scene.json \
  --port 4173
```

Open:

```text
http://127.0.0.1:4173
```

The viewer loads `/scene.json` from the Node preview server. File nodes can be opened to inspect diff hunks. Diff rows use Highlight.js when the CDN script is available, with a lightweight fallback highlighter if the browser cannot load it.

Stop the server with `Ctrl-C` in the terminal running `serve-preview.mjs`.

## 8. Useful Debug Commands

Inspect generated diff JSON:

```bash
sed -n '1,120p' /tmp/gvd-render-repo-diffs/diff.json
```

Inspect semantic output:

```bash
sed -n '1,160p' /tmp/gvd-render-repo-diffs/semantics.json
```

Inspect scene output:

```bash
sed -n '1,160p' /tmp/gvd-render-repo-diffs/scene.json
```

Check that the preview server is serving the scene:

```bash
curl -s http://127.0.0.1:4173/scene.json | sed -n '1,40p'
```

## Current Limitations

- Objective-C and Objective-C++ semantic extraction are not implemented yet.
- Deleted file symbols require semantic input from the base revision; the current CLI extractor reads from the working tree, so the tutorial excludes deleted files from semantic extraction.
- Syntax highlighting is viewer-side via Highlight.js when available. Tree-sitter remains the backend source for semantic symbols.
- The viewer is currently static JS, not TypeScript. The scene JSON contract is the boundary that should stay stable if the renderer is later converted to TS or embedded in a native app.
