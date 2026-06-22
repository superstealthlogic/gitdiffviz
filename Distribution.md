# macOS Distribution

The native application is packaged by Tauri. A release build produces
`Git Visualization Diff.app` and a disk image under
`native/tauri/src-tauri/target/release/bundle/`.

## Homebrew

Homebrew distribution might be best. Noting here to look into
over the next week.

## Prerequisites

- macOS with Xcode Command Line Tools (`xcode-select --install`)
- Rust and Cargo
- Node.js and npm
- OCaml, opam, and Dune with this project's opam dependencies installed

Install the JavaScript build dependency once:

```sh
cd native/tauri
npm ci
```

## Build the bundles

From the repository root:

```sh
cd native/tauri
npm run build
```

To build only the `.app` (for example, when a headless environment cannot run
the DMG layout step):

```sh
cd native/tauri
npm run build -- --bundles app
```

The build script compiles the OCaml backend, packages it as a Tauri sidecar,
and bundles its `libtree-sitter` dynamic library. The outputs are:

```text
native/tauri/src-tauri/target/release/bundle/macos/Git Visualization Diff.app
native/tauri/src-tauri/target/release/bundle/dmg/Git Visualization Diff_0.1.0_aarch64.dmg
```

The current build is Apple Silicon (`aarch64`) only. An Intel Mac cannot run
it. A universal build requires compiling both the OCaml backend and Rust host
for `aarch64-apple-darwin` and `x86_64-apple-darwin`, then combining their
binaries; Tauri cannot make the architecture-specific OCaml sidecar universal
by itself.

## Signing

List available code-signing certificates:

```sh
security find-identity -v -p codesigning
```

For distribution outside the Mac App Store, use an Apple Developer Program
`Developer ID Application` certificate. Before building, set its exact name:

```sh
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
cd native/tauri
npm run build
```

Without a Developer ID certificate, apply an ad-hoc signature after building.
This verifies bundle integrity but does **not** establish developer identity or
satisfy Gatekeeper on another Mac:

```sh
codesign --force --deep --sign - \
  "native/tauri/src-tauri/target/release/bundle/macos/Git Visualization Diff.app"
```

If you ad-hoc sign after Tauri creates the DMG, recreate the DMG or send a zip
made from the signed app. Preserve bundle metadata with `ditto`:

```sh
ditto -c -k --keepParent \
  "native/tauri/src-tauri/target/release/bundle/macos/Git Visualization Diff.app" \
  "Git Visualization Diff.app.zip"
```

## Notarization for normal Gatekeeper installation

Developer ID signing alone is not enough for a frictionless download. Configure
Tauri's Apple signing/notarization environment variables, including
`APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID`, and
run `npm run build`. `APPLE_PASSWORD` should be an app-specific Apple ID
password. Notarization requires Apple Developer Program credentials and network
access.

## Verify the result

Run these checks against the app before sending it:

```sh
APP="native/tauri/src-tauri/target/release/bundle/macos/Git Visualization Diff.app"

test -d "$APP"
file "$APP/Contents/MacOS/git-visualization-diff-app"
file "$APP/Contents/MacOS/git-visualization-diff"
otool -L "$APP/Contents/MacOS/git-visualization-diff"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP"
```

The sidecar's `otool` output must reference
`@executable_path/../Frameworks/libtree-sitter.dylib`, not a path under the
builder's home directory. `codesign --verify` should succeed. An ad-hoc signed,
unnotarized build is expected to fail `spctl`; a notarized Developer ID build
should pass.

As a final smoke test, copy the app or DMG to a Mac without this source tree or
the project's opam switch, launch it, select a Git repository, and render a
diff. This catches missing runtime libraries that signature checks cannot.
