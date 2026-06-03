# Native Tauri App

This directory contains the Tauri macOS host for Git Visualization Diff.

The app bundles the existing static viewer from `../../viewer` and runs the
OCaml CLI as a native subprocess.

## Development

```bash
cd native/tauri
npm install
npm run dev
```

The `dev` and `build` scripts run `scripts/prepare-backend.sh` first. That
builds the OCaml CLI with Dune and copies it into
`src-tauri/binaries/git-visualization-diff-$target_triple` so Tauri can bundle
it as an external binary.

## Build

```bash
cd native/tauri
npm run build
```

The build target is configured for `.app` and `.dmg` bundles.
