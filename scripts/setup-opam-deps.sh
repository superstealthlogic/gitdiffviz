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
    opam switch create . "$ocaml_version" --yes
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
