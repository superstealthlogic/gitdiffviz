#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/render-repo-diffs.sh --repo /path/to/repo [options]

Options:
  --repo PATH       Local git repository checkout. Required.
  --base REV       Base git revision. Default: HEAD~1
  --target REV     Target git revision. Default: HEAD
  --workdir PATH   Output workspace. Default: /tmp/gvd-render-repo-diffs
  --port PORT      Viewer port. Default: 4173
  --timeline       Build and serve adjacent-commit timeline JSON.
  --no-serve       Build JSON artifacts but do not start the viewer.
  --help           Show this help.

The script does not clone repositories. It assumes --repo already exists.
EOF
}

repo=""
base="HEAD~1"
target="HEAD"
workdir="/tmp/gvd-render-repo-diffs"
port="4173"
serve="1"
timeline="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --base)
      base="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --workdir)
      workdir="${2:-}"
      shift 2
      ;;
    --port)
      port="${2:-}"
      shift 2
      ;;
    --timeline)
      timeline="1"
      shift
      ;;
    --no-serve)
      serve="0"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$repo" ]]; then
  echo "Missing required --repo PATH" >&2
  usage >&2
  exit 2
fi

if [[ ! -d "$repo/.git" ]]; then
  echo "Not a git repository: $repo" >&2
  exit 2
fi

mkdir -p "$workdir"

diff_json="$workdir/diff.json"
semantic_files="$workdir/semantic-files.txt"
semantics_json="$workdir/semantics.json"
scene_json="$workdir/scene.json"
timeline_json="$workdir/timeline.json"
file_level_scene_json="$workdir/scene-file-level.json"

echo "Repository: $repo"
echo "Base:       $base"
echo "Target:     $target"
echo "Workspace:  $workdir"

echo
echo "Building OCaml backend..."
opam exec -- dune build

echo
echo "Extracting git diff..."
opam exec -- dune exec git-visualization-diff -- extract-diff \
  --repo "$repo" \
  --base "$base" \
  --target "$target" \
  --out "$diff_json"

echo
echo "Collecting semantic files..."
(
  cd "$repo"
  git diff --name-only --diff-filter=ACMRT "$base" "$target" \
    | grep -E '\.(swift|c|h|cc|cpp|cxx|hh|hpp)$' \
    > "$semantic_files" || true
)

semantic_count="$(wc -l < "$semantic_files" | tr -d ' ')"
echo "Semantic candidate files: $semantic_count"

if [[ "$semantic_count" -gt 0 ]]; then
  echo
  echo "Extracting semantics..."
  mapfile -t files < "$semantic_files"
  opam exec -- dune exec git-visualization-diff -- extract-semantics \
    --repo "$repo" \
    "${files[@]}" \
    --out "$semantics_json"

  echo
  echo "Building semantic scene..."
  opam exec -- dune exec git-visualization-diff -- build-scene \
    --diff "$diff_json" \
    --semantic "$semantics_json" \
    --out "$scene_json"
else
  echo "No current Swift/C/C++ files found in the diff; building file-level scene."
  semantics_json=""
  opam exec -- dune exec git-visualization-diff -- build-scene \
    --diff "$diff_json" \
    --out "$scene_json"
fi

echo
echo "Building file-level fallback scene..."
opam exec -- dune exec git-visualization-diff -- build-scene \
  --diff "$diff_json" \
  --out "$file_level_scene_json"

serve_json="$scene_json"
if [[ "$timeline" == "1" ]]; then
  echo
  echo "Building timeline scene sequence..."
  opam exec -- dune exec git-visualization-diff -- build-timeline \
    --repo "$repo" \
    --base "$base" \
    --target "$target" \
    --out "$timeline_json"
  serve_json="$timeline_json"
fi

cat > "$workdir/open-dark-viewer.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<script>
  localStorage.setItem("git-visualization-diff-theme", "dark");
  location.replace("http://127.0.0.1:$port");
</script>
EOF

echo
echo "Artifacts:"
echo "  $diff_json"
if [[ -n "$semantics_json" ]]; then
  echo "  $semantics_json"
fi
echo "  $scene_json"
if [[ "$timeline" == "1" ]]; then
  echo "  $timeline_json"
fi
echo "  $file_level_scene_json"
echo "  $semantic_files"

if [[ "$serve" == "1" ]]; then
  echo
  echo "Starting dark-mode viewer at http://127.0.0.1:$port"
  echo "If your browser previously used light mode, open $workdir/open-dark-viewer.html once or toggle back to dark."
  exec node viewer/serve-preview.mjs --scene "$serve_json" --port "$port"
fi

echo
echo "Viewer not started. Start it with:"
echo "  node viewer/serve-preview.mjs --scene $serve_json --port $port"
