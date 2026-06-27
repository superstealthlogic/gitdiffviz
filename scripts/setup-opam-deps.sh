#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/setup-opam-deps.sh [options]

Options:
  --ocaml VERSION      OCaml compiler version for a new local switch.
                       Default: 5.2.1
  --no-local-switch    Use the currently selected opam switch instead of
                       creating or selecting this repo's local switch.
  --without-test       Install only build dependencies.
  --no-build           Install dependencies without running dune build.
  --runtest            Run dune runtest after a successful build.
  --help               Show this help.

This installs the opam dependencies needed by dune, including the pinned
tree-sitter runtime that provides tree-sitter.bindings and tree-sitter.run.
EOF
}

ocaml_version="5.2.1"
local_switch="1"
with_test="1"
run_build="1"
run_tests="0"
tree_sitter_pin="git+https://github.com/semgrep/ocaml-tree-sitter-core.git#d521f0a0791d94f4442cf9be08322f6aabce20d6"

install_tree_sitter_runtime() {
  local opam_prefix
  local tree_sitter_source

  opam_prefix="$(opam var prefix)"
  tree_sitter_source="$opam_prefix/.opam-switch/sources/tree-sitter"

  if [[ ! -d "$tree_sitter_source" ]]; then
    echo "Missing pinned tree-sitter source directory: $tree_sitter_source" >&2
    return 1
  fi

  (
    cd "$tree_sitter_source"
    STRIP="${STRIP:-true}" scripts/install-tree-sitter-lib --prefix "$opam_prefix"
  )

  TREESITTER_INCDIR="$opam_prefix/include" \
    TREESITTER_LIBDIR="$opam_prefix/lib" \
    "$opam_prefix/bin/dune" build \
      --root "$tree_sitter_source" \
      --display short \
      @install

  TREESITTER_INCDIR="$opam_prefix/include" \
    TREESITTER_LIBDIR="$opam_prefix/lib" \
    "$opam_prefix/bin/dune" install tree-sitter \
      --root "$tree_sitter_source" \
      --prefix "$opam_prefix" \
      --display short
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ocaml)
      ocaml_version="${2:-}"
      if [[ -z "$ocaml_version" ]]; then
        echo "Missing value for --ocaml" >&2
        exit 2
      fi
      shift 2
      ;;
    --no-local-switch)
      local_switch="0"
      shift
      ;;
    --without-test)
      with_test="0"
      shift
      ;;
    --no-build)
      run_build="0"
      shift
      ;;
    --runtest)
      run_tests="1"
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

if ! command -v opam >/dev/null 2>&1; then
  echo "opam is required. Install opam 2.x, then rerun this script." >&2
  exit 1
fi

if [[ ! -f dune-project || ! -f git_visualization_diff.opam ]]; then
  echo "Run this script from the repository root." >&2
  exit 2
fi

if [[ "$local_switch" == "1" ]]; then
  if [[ ! -d _opam ]]; then
    echo "Creating local opam switch with OCaml $ocaml_version..."
    switch_create_args=(switch create . "$ocaml_version" --deps-only --yes)
    if [[ "$with_test" == "1" ]]; then
      switch_create_args+=(--with-test)
    fi
    opam "${switch_create_args[@]}"
  else
    echo "Using existing local opam switch in ./_opam"
  fi

  eval "$(opam env --switch=. --set-switch)"
else
  echo "Using currently selected opam switch: $(opam switch show)"
  eval "$(opam env)"
fi

install_args=(install . --deps-only --yes)
if [[ "$with_test" == "1" ]]; then
  install_args+=(--with-test)
fi

echo
echo "Installing project dependencies..."
opam "${install_args[@]}"

if ! opam exec -- ocamlfind query tree-sitter.run >/dev/null 2>&1; then
  echo
  echo "tree-sitter.run is missing; pinning and installing the tested tree-sitter runtime..."
  opam pin add tree-sitter.dev "$tree_sitter_pin" --no-action --yes
  if opam list --installed --short tree-sitter | grep -qx tree-sitter; then
    opam reinstall tree-sitter --yes
  else
    opam install tree-sitter --yes
  fi
  install_tree_sitter_runtime
fi

if ! opam exec -- ocamlfind query tree-sitter.run >/dev/null 2>&1; then
  cat >&2 <<'EOF'

tree-sitter.run is still not available in the selected opam switch.
Try removing the local switch and rerunning this script:
  rm -rf _opam
  scripts/setup-opam-deps.sh --runtest
EOF
  exit 1
fi

if [[ "$run_build" == "1" ]]; then
  echo
  echo "Building with dune from the selected opam switch..."
  opam exec -- dune build
fi

if [[ "$run_tests" == "1" ]]; then
  echo
  echo "Running tests..."
  opam exec -- dune runtest
fi

cat <<'EOF'

Dependency setup complete.

Use this form for future commands so Dune sees the same switch:
  opam exec -- dune build

For an interactive shell in this repo's local switch, run:
  eval "$(opam env --switch=. --set-switch)"
EOF
