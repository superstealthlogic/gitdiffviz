# Tauri Native App Plan

## Goal

Build a native macOS app for Git Visualization Diff using Tauri as the host
shell, while keeping the existing OCaml backend and JS/SVG viewer as the core
application pieces.

The native app should let a user choose a local git repository, select a base
and target revision, run the diff visualization pipeline, and view the generated
scene inside a bundled macOS `.app`.

## Current Application Shape

The repository already has a useful split:

- `bin/main.ml` exposes the OCaml CLI commands for extracting diffs, extracting
  semantics, building scenes, and building timelines.
- `viewer/index.html`, `viewer/app.js`, and `viewer/styles.css` render a scene
  document in the browser.
- `viewer/serve-preview.mjs` serves static viewer files and maps `/scene.json`
  to a generated JSON document.
- `scripts/render-repo-diffs.sh` orchestrates the current end-to-end local
  workflow.

The Tauri app should preserve this split. Tauri should own native app concerns,
not replace the analysis pipeline or renderer.

## Recommended Architecture

```text
GitVisualizationDiff.app
  Contents/
    MacOS/
      git-visualization-diff-app   # Tauri host executable
    Resources/
      git-visualization-diff       # Bundled OCaml CLI
      viewer/
        index.html
        app.js
        styles.css
        vendor/
          highlight.min.js
```

Responsibilities:

- OCaml CLI: produce diff, semantic, scene, and timeline JSON.
- Tauri backend: select folders, run the OCaml binary, manage temp/cache files,
  report progress/errors, and expose generated scene JSON to the WebView.
- Viewer frontend: render and interact with the scene.

## Phase 1: Prepare The Existing App For Embedding

1. Vendor browser dependencies.
   - Replace the Highlight.js CDN URL in `viewer/index.html` with a local
     bundled file.
   - Keep the viewer usable without internet access.

2. Make scene loading host-friendly.
   - Keep support for loading `/scene.json` during local preview.
   - Add an alternate scene-loading path for Tauri, such as calling a Tauri
     command or reading from an app-provided URL.
   - Avoid baking development server assumptions into `viewer/app.js`.

3. Keep `viewer/serve-preview.mjs`.
   - The local browser preview remains useful for development and regression
     checks.
   - Tauri should not depend on Node at runtime.

## Phase 2: Add A Single App-Facing OCaml Command

Add a CLI command that wraps the scripted workflow currently implemented in
`scripts/render-repo-diffs.sh`.

Example command:

```bash
git-visualization-diff render-repo \
  --repo /path/to/repo \
  --base HEAD~1 \
  --target HEAD \
  --timeline \
  --out /tmp/git-visualization-diff/scene.json
```

Behavior:

- Validate that `--repo` points to a git repository.
- Extract the structured git diff.
- Collect semantic candidate files.
- Extract semantics when supported source files are present.
- Build the semantic scene when possible.
- Always build a file-level fallback scene.
- Build a timeline document when `--timeline` is enabled.
- Write a single renderer-ready JSON document to `--out`.

This keeps the Tauri backend simple: one subprocess call produces one renderable
document.

## Phase 3: Scaffold The Tauri App

Add a Tauri app alongside the existing project, likely under `native/tauri/` or
`app/`.

Initial app features:

- Open a macOS folder picker for choosing a repository.
- Provide text inputs for base and target revisions.
- Default `base` to `HEAD~1`.
- Default `target` to `HEAD`.
- Provide a timeline toggle.
- Run the bundled OCaml CLI through a Tauri command.
- Stream progress and errors into the app UI.
- Load the generated scene into the existing viewer.

The first native UI should be small and functional. The main product experience
is still the visualization, not a landing page.

## Phase 4: Bundle The OCaml Backend

Build the OCaml executable with Dune and include it as a Tauri resource.

Items to verify:

- The produced executable runs outside the development tree.
- Tree-sitter parser C stubs are linked correctly.
- Runtime dependencies are either statically linked or bundled.
- The app can run without `opam`, `dune`, or Node installed.
- The app can invoke the system `git` binary.

The bundled executable should be treated as an implementation detail of the
native app. Users should not need to know about the CLI pipeline.

## Phase 5: Replace Local HTTP Assumptions

The current preview server maps `/scene.json` to a selected JSON file. In Tauri,
prefer one of these approaches:

1. Tauri command based loading.
   - `viewer/app.js` calls `window.__TAURI__.core.invoke("load_scene")`.
   - The Rust backend returns the current scene JSON.

2. Custom protocol based loading.
   - Register an app protocol that serves `viewer/` assets and `scene.json`.
   - Keep the viewer code close to the current browser version.

The command-based path is simpler for a first version. A custom protocol may be
cleaner later if the viewer gains more static assets or exported files.

## Phase 6: Native App Polish

Add macOS affordances after the first complete workflow works:

- Recent repositories.
- App menu items for Open Repository, Reload, Export Scene JSON, and Export
  Snapshot.
- Persist last-used base and target values per repository.
- Show subprocess progress in a compact status area.
- Cancel in-progress analysis.
- Handle invalid revisions and non-git folders with clear errors.
- Store generated artifacts under the app cache directory.

## Phase 7: Packaging And Distribution

Use Tauri's bundler to produce:

- `.app` for local development.
- `.dmg` for manual distribution.

Before wider distribution:

- Configure app identifier and icons.
- Sign with an Apple Developer ID certificate.
- Notarize the app.
- Verify the app on a clean macOS account or machine.

## Main Risks

- OCaml executable portability outside the opam development environment.
- Dynamic library linkage for C stubs and parser dependencies.
- Differences between browser preview loading and Tauri WebView loading.
- Long-running repository analysis needing cancellation and progress reporting.
- macOS permissions and sandbox behavior when reading arbitrary repository
  folders.

## First Milestone

The first milestone should be:

1. Build a `render-repo` OCaml command.
2. Vendor Highlight.js locally.
3. Scaffold a Tauri app that bundles the viewer.
4. Add a folder picker and base/target inputs.
5. Run the bundled CLI and render the generated scene in the WebView.

At that point the project has a real native macOS app path without rewriting
the backend or renderer.
