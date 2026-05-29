# OCaml Port Plan for Git Visualization Diff

## Summary

Porting `logic-smasher/ninja-rz-logic/visualization-diff` to OCaml is a good idea if the goal is to create robust, language-aware git diff visualizations rather than only prettier file-level diffs.

The strongest reason to do it is architectural: the current JavaScript implementation already separates extraction, hierarchy building, semantic joining, scene generation, and rendering. OCaml is a good fit for turning those middle layers into a typed, testable diff-analysis engine. Tree-sitter gives the project a realistic path to multi-language syntax support, and OCaml's algebraic data types make it easier to model partial, uncertain, or language-specific semantic information without turning the pipeline into loosely validated JSON plumbing.

The main cost is that this is not just a line-for-line rewrite. The useful port is a backend rewrite plus a stable renderer contract. Expect roughly:

- 1-2 weeks for an MVP that reproduces the current diff, hierarchy, scene JSON, and JS preview workflow.
- 3-5 additional weeks for robust tree-sitter semantic extraction across two or three languages.
- 2-4 more weeks for hardening: renamed/deleted symbol handling, performance profiling, snapshot tests, packaged grammars, and a cleaner JS/TS renderer API.

The risky part is not OCaml itself. The risky part is language packaging and semantic normalization: each tree-sitter grammar exposes a different CST shape, and robust symbol extraction needs per-language adapters. OCaml helps keep that complexity contained, but it does not remove it.

Recommendation: do the port, but keep the renderer in JS/TS and treat OCaml as the analysis engine that emits versioned scene JSON. That keeps future options open for a browser viewer, VS Code/webview integration, Electron/Tauri, or a later native shell.

## Current Tool Shape

The existing `visualization-diff` tool has these pipeline layers:

1. `src/gitDiff.mjs`
   - Runs git commands.
   - Parses `--name-status`, `--numstat`, and unified diff output.
   - Produces a diff document with file status, additions, deletions, hunks, and line-level changes.

2. `src/hierarchy.mjs`
   - Converts a diff document into repository, directory, and file nodes.
   - Adds language tags from extensions.
   - Computes line counts, changed ratios, and parent aggregate metrics.
   - Optionally includes unchanged tracked files with `--whole-repo`.

3. `src/semanticJoin.mjs`
   - Joins analyzer-provided semantic symbols to changed files.
   - Uses source spans to estimate which symbols overlap diff hunks.
   - Bubbles semantic metadata such as patterns, paradigms, issues, and severity upward.

4. `src/sceneBuilder.mjs`
   - Converts hierarchy or semantic hierarchy data into renderer-ready scene JSON.
   - Adds render hints, issue-marker nodes, assets, legend entries, and metrics.

5. `viewer/*`
   - A standalone JS/SVG preview renderer.
   - It consumes scene JSON directly, so it can remain mostly independent of the backend language.

The OCaml port should preserve this decomposition.

## Target Architecture

Use OCaml for the analysis backend and JS/TS for the renderer.

```text
git revisions / saved diff
        |
        v
OCaml CLI: git diff extraction
        |
        v
OCaml core: diff document
        |
        v
OCaml core: repository hierarchy
        |
        v
OCaml tree-sitter adapters: semantic symbols
        |
        v
OCaml core: semantic join
        |
        v
OCaml core: scene JSON
        |
        v
JS/TS renderer or native host webview
```

Keep the JSON scene contract as the main boundary. If a future native app is built, it can either embed a web renderer or call the OCaml library directly.

## Repository Layout

Create the OCaml project inside `GitVisualizationDiff`:

```text
GitVisualizationDiff/
  README.md
  OcamlPortPlan.md
  dune-project
  git_visualization_diff.opam
  bin/
    main.ml
  lib/
    diff_types.ml
    diff_types.mli
    git_diff.ml
    git_diff.mli
    hierarchy.ml
    hierarchy.mli
    semantic_types.ml
    semantic_types.mli
    semantic_join.ml
    semantic_join.mli
    scene.ml
    scene.mli
    config.ml
    config.mli
    language.ml
    language.mli
    json_codec.ml
    json_codec.mli
  lib_tree_sitter/
    parser_registry.ml
    parser_registry.mli
    symbol_extractor_intf.ml
    rust_symbols.ml
    cpp_symbols.ml
    ocaml_symbols.ml
  viewer/
    index.html
    styles.css
    app.ts
  examples/
    sample-diff.json
    sample-hierarchy.json
    sample-semantic-input.json
    sample-semantic-hierarchy.json
    sample-scene.json
  test/
    diff_parser_tests.ml
    hierarchy_tests.ml
    semantic_join_tests.ml
    scene_snapshot_tests.ml
    fixtures/
```

The `viewer/` can initially be copied from the existing tool and converted to TypeScript later. Do not force the OCaml port to solve renderer design in the first milestone.

## Suggested OCaml Dependencies

Use conservative, mainstream OCaml libraries:

- `dune` for builds.
- `cmdliner` for CLI parsing.
- `yojson` or `ppx_deriving_yojson` for JSON encoding.
- `alcotest` for tests.
- `bos` or direct `Unix.create_process` wrappers for git command execution.
- `ptime` only if timestamps enter the schema later.
- `tree-sitter` OCaml bindings for generic parser access.

As of the latest check, `opam` has a `tree-sitter` package described as minimal GC-managed OCaml bindings, and upstream tree-sitter documents OCaml among supported language bindings. Treat that as enough for a prototype, but not as proof that every grammar will package cleanly. The plan should allow either:

- dynamically loaded grammar libraries,
- vendored grammar C sources built by dune,
- or a separate `tree-sitter-language-pack` style helper later.

## Data Model

Port the existing TypeScript shapes into OCaml records and variants.

Core types:

```ocaml
type diff_file_status =
  | Unchanged
  | Modified
  | Added
  | Deleted
  | Renamed
  | Copied
  | Type_changed
  | Unmerged
  | Unknown

type source_span = {
  start_line : int;
  end_line : int;
}

type diff_metrics = {
  lines_added : int;
  lines_removed : int;
  changed_ratio : float;
}

type semantic_symbol_kind =
  | Type_container
  | Function
  | Symbol
```

Keep renderer-facing JSON names stable:

- `type_container`, not `Type_container`
- `linesAdded`, not `lines_added`
- `parentSymbolId`, not `parent_symbol_id`

That means JSON codecs should be explicit rather than relying blindly on OCaml constructor names.

## CLI Contract

Provide one binary, `git-visualization-diff`, with subcommands:

```bash
git-visualization-diff extract-diff \
  --repo . \
  --base HEAD~1 \
  --target HEAD \
  --out /tmp/repo-diff.json

git-visualization-diff build-hierarchy \
  --diff /tmp/repo-diff.json \
  --out /tmp/repo-hierarchy.json

git-visualization-diff extract-semantics \
  --repo . \
  --files src/lib.rs src/main.ml \
  --out /tmp/semantics.json

git-visualization-diff build-scene \
  --diff /tmp/repo-diff.json \
  --semantic /tmp/semantics.json \
  --out /tmp/visualization-scene.json

git-visualization-diff preview \
  --scene /tmp/visualization-scene.json \
  --port 4173
```

For compatibility with the existing tool, also support direct revision input:

```bash
git-visualization-diff build-scene \
  --repo . \
  --base HEAD~3 \
  --target HEAD \
  --whole-repo \
  --out /tmp/visualization-scene.json
```

## Phase 0: Preserve the Contract

Before porting behavior, freeze the schema.

Tasks:

- Copy the existing examples into `GitVisualizationDiff/examples`.
- Write JSON schema notes in `README.md`.
- Add OCaml round-trip tests for sample diff, hierarchy, semantic hierarchy, and scene files.
- Keep `version: 1` for compatible output.
- Add golden-output tests that compare OCaml-emitted JSON to normalized existing JS output.

Acceptance criteria:

- The OCaml code can read and write all existing sample documents.
- The JS viewer can load a scene emitted by OCaml.

## Phase 1: Port Git Diff Extraction

Implement `Git_diff.extract`.

Behavior to match:

- Resolve `repoRoot` with `git rev-parse --show-toplevel`.
- Use `git diff --name-status`, `--numstat`, and unified diff output.
- Parse modified, added, deleted, renamed, copied, type-changed, unmerged, and unknown status codes.
- Parse hunk headers and line-level additions/deletions/context.
- Support `pathFilter`.

Design notes:

- Keep git invocation isolated in one module for testability.
- Parse saved command output in unit tests without invoking git.
- Use explicit buffer limits or streaming to avoid surprise memory blowups on large repos.

Acceptance criteria:

- Matches existing `sample-diff.json`.
- Handles rename and binary-file fixtures.
- Produces deterministic file ordering.

## Phase 2: Port Repository Hierarchy

Implement `Hierarchy.build`.

Behavior to match:

- Create repository, directory, and file nodes.
- Compute `lineCount`.
- Compute `changedRatio`.
- Preserve hunk and line-change metadata on file nodes.
- Aggregate additions, deletions, line counts, and changed ratios upward.
- Support `--whole-repo` by calling `git ls-files`.

Design notes:

- Use `Map.Make(String)` for stable node lookup.
- Centralize path normalization to POSIX-style `/` paths, even on macOS/Linux.
- Make language detection a replaceable module rather than a hard-coded map in the hierarchy builder.

Acceptance criteria:

- Existing sample hierarchy can be reproduced.
- Whole-repo mode includes unchanged tracked files as low-priority context.

## Phase 3: Port Scene Builder

Implement `Scene.build`.

Behavior to match:

- Convert hierarchy nodes into scene nodes.
- Emit `contains` edges.
- Add issue marker nodes and `annotates` edges.
- Add render hints.
- Emit assets and legend entries.
- Preserve current config defaults.

Design notes:

- Keep render hints minimal and data-driven.
- Do not encode layout decisions in OCaml. The renderer should own layout.
- Add a `configApplied` field so scenes are self-describing.

Acceptance criteria:

- JS viewer renders an OCaml scene.
- Snapshot tests prove stable output for sample inputs.

## Phase 4: Port Semantic Join

Implement `Semantic_join.build`.

Behavior to match:

- Attach symbols under file nodes.
- Use `span.startLine` and `span.endLine` to compute hunk overlap.
- Attribute additions and deletions to symbols.
- Preserve `languageKind`.
- Bubble semantic metadata upward.
- Emit `sourceSymbolId`.

Important improvement over current JS:

- Model old and new spans explicitly in the type system, even if v1 only populates current spans.

Suggested type:

```ocaml
type symbol_span =
  | Current of source_span
  | Before_after of { old_span : source_span option; new_span : source_span option }
```

This prepares the backend for better deletion and rename handling later.

Acceptance criteria:

- Existing sample semantic hierarchy can be reproduced.
- Added, deleted, and modified lines are attributed to symbol nodes.
- Deletion-only changes are called out as heuristic when only current spans are available.

## Phase 5: Tree-sitter Semantic Extraction

Build a language-adapter layer rather than one giant generic extractor.

Current scaffold status:

- `Symbol_extractor_intf.S` defines the adapter boundary.
- `Parser_registry` dispatches to Rust, C/C++, and Swift adapters by detected language.
- `Semantic_extract.extract` reads requested files and emits a `SemanticInputDocument`.
- The Rust adapter now uses tree-sitter to emit syntax-level symbols for structs, enums, traits, impls, modules, functions, methods, and common test markers.
- C/C++ now uses tree-sitter to emit syntax-level symbols for classes, structs, unions, enums, namespaces, functions, class-contained methods, and template classes/functions.
- Swift now uses tree-sitter to emit syntax-level symbols for classes, structs, enums, actors, extensions, protocols, functions, methods, initializers, deinitializers, properties, type aliases, and generic declarations.
- `Symbol_normalization` centralizes symbol IDs, source spans, sorting, and generic/template semantic tags so the first three adapters produce more consistent output.
- Semantic extraction now has a golden JSON snapshot for the Rust, C/C++, and Swift fixtures.
- Semantic join now prefers precise hunk-line overlap over coarse line-change ranges and projects deletion-only hunks into nearby current-file spans for better symbol attribution.
- Semantic join now handles deleted-file symbols and rename old-path matching at the file/symbol-node level. Full before/after symbol identity matching remains future work.

Rust adapter limitations:

- It is tree-sitter-backed, but still intentionally syntax-level.
- It does not perform macro expansion, name resolution, trait resolution, or cross-file matching.
- It intentionally favors stable spans and useful hierarchy over complete Rust semantics.

C/C++ adapter limitations:

- It is tree-sitter-backed, but intentionally syntax-level.
- It does not require compile commands, include resolution, macro expansion, template instantiation, overload resolution, or cross-translation-unit matching.
- It classifies functions nested directly under class/struct/union nodes as methods; out-of-class qualified method definitions are a later improvement.
- Template support is declaration-level: template classes/functions get full template spans and generic metadata, but template specialization and instantiation are not resolved.

Swift adapter limitations:

- It is tree-sitter-backed, but intentionally syntax-level.
- It does not perform type checking, overload resolution, protocol conformance analysis, extension merging, macro expansion, or cross-file symbol matching.
- It currently favors declaration spans and parent relationships over complete Swift semantic modeling.

Core signature:

```ocaml
module type SYMBOL_EXTRACTOR = sig
  val language : string
  val extensions : string list
  val extract :
    repo_root:string ->
    path:string ->
    source:string ->
    semantic_symbol list
end
```

Start with these preliminary language adapters:

1. Rust
2. C/C++
3. Swift

Rust comes first because the current examples and prior adaptor work are Rust-derived. C/C++ comes second because it is the highest-value systems-language target for vulnerability and patch review workflows. Swift is the third preliminary target because it exercises a different modern language family with classes, structs, extensions, protocols, enums, methods, properties, async constructs, and platform-heavy codebases.

Do not treat this as the complete language set. OCaml, TypeScript/JavaScript, Python, Mojo, and other languages remain good later candidates, but the initial adapter work should stay focused on these three until the extractor interface, grammar packaging, and scene semantics are proven.

Per-language extraction should produce:

- stable symbol id,
- renderer-facing kind,
- language-specific kind,
- display name,
- optional parent symbol id,
- source span,
- optional semantic metadata.

Renderer-facing kind mapping:

- modules, classes, structs, enums, traits, impls, namespaces -> `type_container`
- functions, methods, values with function bodies -> `function`
- constants, fields, macros, type aliases, declarations -> `symbol`

Do not require full name resolution for v1. Syntax-level spans are enough to answer whether a diff touched a declaration or body.

Acceptance criteria:

- A changed Rust file produces symbol nodes under changed files.
- A changed C/C++ file produces class/function/method nodes.
- A changed Swift file produces class/struct/enum/protocol/extension/function/method/property nodes.
- Semantic extractor JSON output is covered by a stable golden snapshot.
- Unknown language files still appear at file level.

## Phase 6: Renderer Boundary

Keep the renderer JS/TS.

Short-term:

- Copy/adapt the current `viewer`.
- Update it to load scenes from the OCaml CLI.
- Convert `app.js` to `app.ts` only after backend behavior is stable.

Current status:

- `viewer/index.html`, `viewer/styles.css`, and `viewer/app.js` load OCaml scene JSON from `/scene.json`.
- `viewer/serve-preview.mjs` serves the static viewer and a selected scene file.
- The viewer keeps the original zoom/card/file-diff flow and uses Highlight.js for diff-row syntax highlighting when available, with a lightweight fallback highlighter.
- `build-timeline` emits adjacent-commit scene steps between two revisions, and the viewer shows a right-side slider with tick marks, 8-character hashes, endpoint dates, and a dissolve transition between steps.

Medium-term:

- Define a small renderer package that accepts a `VisualizationDocument`.
- Keep layout, zoom, selection, and theme state in TypeScript.
- Keep scene generation, semantic extraction, and git operations in OCaml.

Possible hosts:

- plain browser preview,
- VS Code webview,
- Electron,
- Tauri,
- native OCaml app embedding a webview.

This is the right flexibility point: the renderer needs browser-grade interaction and layout tools, while the backend needs typed analysis and deterministic CLI behavior.

## Phase 7: Robustness Work

After parity, improve the model beyond the current JS implementation.

High-value improvements:

- Parse both base and target revisions for semantic extraction.
- Join additions against target spans and deletions against base spans.
- Add stable symbol identity across revisions using path, qualified name, kind, and fuzzy span matching.
- Track moved/renamed symbols separately from changed symbols.
- Add direct-vs-aggregated change flags:
  - `directlyChanged`
  - `containsChangedDescendant`
  - `aggregatedOnly`
- Add scene-size limits and lazy expansion hints.
- Add performance tests on large repositories.
- Add grammar availability diagnostics.

## Testing Strategy

Use four levels of tests:

1. Parser tests
   - Git diff text to `GitDiffDocument`.
   - Tree-sitter CST to semantic symbols.

2. Pipeline tests
   - Diff document to hierarchy.
   - Diff plus semantic input to semantic hierarchy.
   - Semantic hierarchy to scene.

3. Snapshot tests
   - Normalize JSON object order.
   - Compare against checked-in expected files.

4. End-to-end tests
   - Create temporary git repositories.
   - Commit base and target states.
   - Run `build-scene`.
   - Validate that expected file and symbol nodes exist.

For renderer verification, keep a small Playwright smoke test once the viewer moves into this repo:

- load sample scene,
- confirm SVG nodes render,
- click a node,
- confirm selection panel updates.

## Packaging Strategy

The simplest early packaging is:

- `opam install . --deps-only`
- `dune build`
- `dune exec git-visualization-diff -- build-scene ...`

Grammar packaging needs an explicit decision:

1. Dynamic grammar libraries
   - Flexible.
   - More fragile for users.

2. Vendored grammar C sources compiled by dune
   - Better for reproducible CLI binaries.
   - More maintenance when grammars update.

3. Optional language plugin packages
   - Clean long-term model.
   - More packaging work.

Recommended path:

- MVP: support no tree-sitter or one vendored grammar.
- Early robust version: vendor Rust, C, C++, and Swift grammars.
- Later: split grammars into optional packages if binary size or update cadence becomes a problem.

## Work Estimate

MVP parity:

- Project scaffold and codecs: 1-2 days.
- Git diff extraction: 2-3 days.
- Hierarchy builder: 1-2 days.
- Scene builder: 1-2 days.
- Semantic join: 2-3 days.
- CLI and examples: 1 day.
- Tests and cleanup: 2-3 days.

Subtotal: about 2 focused weeks.

Tree-sitter semantic extraction:

- Parser registry and grammar strategy: 2-4 days.
- Rust extractor: 2-4 days.
- C/C++ extractor: 4-7 days.
- Swift extractor: 3-6 days.
- Cross-language semantic normalization: 3-5 days.

Subtotal: about 3-5 weeks, depending on grammar packaging friction.

Hardening:

- Base/target semantic comparison: 1-2 weeks.
- Symbol identity and rename/move handling: 1-2 weeks.
- Renderer TypeScript cleanup and host API: 1 week.
- Large-repo performance work: 1 week.

Subtotal: about 4-6 weeks for a genuinely robust tool.

## Main Risks

1. Grammar packaging
   - Tree-sitter's architecture is portable, but OCaml packaging for many grammars may need custom dune stanzas or vendored C builds.

2. Language-specific CST variance
   - A generic tree walk will not produce good symbols for every language. Each serious language needs an adapter.

3. Deleted-code attribution
   - Current-span-only semantic extraction is inherently weak for deletions. Robust deletion handling needs parsing both revisions.

4. Scene size
   - Large repositories can produce large JSON. The renderer will need filtering, lazy expansion, or zoom-level policies.

5. Semantic expectations
   - Tree-sitter gives syntax, not type checking or full semantic resolution. The tool should describe itself as syntax-aware and symbol-aware unless deeper analyzers are plugged in.

## Decision

Yes, this is a good idea if the goal is robust git diff visualization with language-aware structure. OCaml is a strong backend choice because the problem is mostly typed tree transformation, normalization, and deterministic serialization.

The cost is moderate for parity and significant for robustness. A simple port can be useful in about two weeks, but the compelling version is closer to two or three months of part-time work or six to ten focused engineering weeks. The payoff is a cleaner architecture: OCaml owns correctness and semantic extraction; JS/TS owns rendering and interaction.
