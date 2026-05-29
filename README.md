# Git Visualization Diff

This is the OCaml port scaffold for `visualization-diff`.

See [Tutorial.md](Tutorial.md) for a start-to-finish walkthrough. It uses
`getsentry/sentry-cocoa` as an example repository, but the workflow is generic.

The project keeps a hard boundary between:

- OCaml analysis code: diff documents, repository hierarchy, semantic joins, and scene JSON.
- JS/TS renderer code: interactive rendering, layout, zooming, and host integration.

Current status:

- Core OCaml types are in place.
- JSON codecs cover the foundational diff and hierarchy documents.
- The CLI has a working `build-hierarchy` command.
- The CLI can build semantic hierarchy and renderer scene JSON from saved inputs.
- The CLI can extract structured git diff JSON from two revisions.
- The CLI can emit semantic input JSON for recognized source files.
- Rust semantic extraction is tree-sitter-backed for basic syntax-level symbols.
- C/C++ semantic extraction is tree-sitter-backed for basic syntax-level symbols.
- Swift semantic extraction is tree-sitter-backed for basic syntax-level symbols.
- Adapter output now shares common symbol ID, span, sort, and generic metadata helpers.
- Semantic extraction has a golden JSON snapshot covering Rust, C/C++, and Swift fixtures.
- Semantic joins use precise hunk-line overlap when available, including deletion-only projection into current-file symbol spans.
- Semantic joins preserve symbol nodes for deleted files and can attach semantic input from a renamed file's old path to the current file node.
- A JS/SVG viewer can load OCaml scene JSON through `/scene.json`; diff rows use Highlight.js when available, with a lightweight fallback highlighter.

Rust extraction currently recognizes:

- `struct`, `enum`, `trait`, `impl`, `mod`
- free functions and methods inside `impl`, `trait`, and module blocks
- `#[test]`, `#[tokio::test]`, `#[async_std::test]`, and `#[cfg(test)]` as test-oriented semantic hints

The Rust grammar is vendored from `tree-sitter-rust` under
`vendor/tree-sitter-rust`. The generated C parser is regenerated with the local
tree-sitter 0.22.6 CLI so it matches the installed OCaml tree-sitter runtime.

C/C++ extraction currently recognizes:

- `class`, `struct`, `union`, `enum`, and `namespace`
- function definitions
- method-like function definitions nested under class/struct/union nodes
- template classes/functions, tagged with `template` and `generic` semantic metadata

The C++ grammar is vendored from `tree-sitter-cpp` under
`vendor/tree-sitter-cpp`.

Swift extraction currently recognizes:

- `class`, `struct`, `enum`, `actor`, `extension`, and `protocol`
- free functions and methods nested under type-like declarations
- initializers, deinitializers, properties, and type aliases
- generic declarations, tagged with `generic` semantic metadata

The Swift grammar is vendored from `tree-sitter-swift` under
`vendor/tree-sitter-swift`. The generated parser is produced with the local
tree-sitter 0.22.6 CLI so it matches the installed OCaml tree-sitter runtime.

Example:

Extract a diff from git:

```bash
opam exec -- dune exec git-visualization-diff -- extract-diff \
  --repo . \
  --base HEAD~1 \
  --target HEAD \
  --out /tmp/repo-diff.json
```

```bash
opam exec -- dune exec git-visualization-diff -- build-hierarchy \
  --diff examples/sample-diff.json \
  --out /tmp/repo-hierarchy.json
```

Build a scene without semantic symbols:

```bash
opam exec -- dune exec git-visualization-diff -- build-scene \
  --diff examples/sample-diff.json \
  --out /tmp/visualization-scene.json
```

Extract semantic input for recognized files:

```bash
opam exec -- dune exec git-visualization-diff -- extract-semantics \
  --repo . \
  src/lib.rs src/widget.cpp Sources/App.swift \
  --out /tmp/semantics.json
```

Build a scene with semantic symbols:

```bash
opam exec -- dune exec git-visualization-diff -- build-scene \
  --diff examples/sample-diff.json \
  --semantic examples/sample-semantic-input.json \
  --out /tmp/visualization-scene.json
```

Preview an OCaml-generated scene:

```bash
node viewer/serve-preview.mjs \
  --scene /tmp/visualization-scene.json \
  --port 4173
```

Then open `http://127.0.0.1:4173`.

For a local git repository, the scripted path is:

```bash
scripts/render-repo-diffs.sh --repo /path/to/repo
```

On this machine, use `opam exec -- dune ...` so dune resolves to the opam
switch version rather than the older Homebrew binary.
