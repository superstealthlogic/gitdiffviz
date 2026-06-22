#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
binary_dir="$repo_root/native/tauri/src-tauri/binaries"
framework_dir="$repo_root/native/tauri/src-tauri/frameworks"
backend="$repo_root/_build/default/bin/main.exe"
target_triple="$(rustc -vV | sed -n 's/^host: //p')"

cd "$repo_root"
opam exec -- dune build

mkdir -p "$binary_dir"
target="$binary_dir/git-visualization-diff-$target_triple"
if [[ -e "$target" ]]; then
  chmod u+w "$target"
fi
cp "$backend" "$target"
chmod 755 "$target"

# The opam tree-sitter package is a dynamic library. Its build output records an
# absolute path into the developer's opam switch, which will not exist on an end
# user's Mac. Bundle the library and point the sidecar at the app-local copy.
tree_sitter_dylib="$(otool -L "$backend" | awk '/libtree-sitter.*\.dylib/{print $1; exit}')"
if [[ -n "$tree_sitter_dylib" ]]; then
  mkdir -p "$framework_dir"
  dylib_name="libtree-sitter.dylib"
  bundled_dylib="$framework_dir/$dylib_name"
  cp "$tree_sitter_dylib" "$bundled_dylib"
  chmod u+w "$bundled_dylib"
  install_name_tool -id "@rpath/$dylib_name" "$bundled_dylib"
  install_name_tool -change "$tree_sitter_dylib" \
    "@executable_path/../Frameworks/$dylib_name" "$target"
fi

echo "Prepared $target"
