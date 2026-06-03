#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
binary_dir="$repo_root/native/tauri/src-tauri/binaries"
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

echo "Prepared $target"
