(lang dune 3.16)

(name git_visualization_diff)

(authors "Jared Carlson")

(maintainers "Jared Carlson <jared.carlson23@gmail.com>")

(homepage "https://github.com/superstealthlogic/gitdiffviz")

(bug_reports "https://github.com/superstealthlogic/gitdiffviz/issues")

(generate_opam_files true)

(package
 (name git_visualization_diff)
 (synopsis "Typed OCaml backend for git diff visualization scene generation")
 (license MIT)
 (depends
  ocaml
  dune
  yojson
  cmdliner
  (alcotest :with-test)
  tree-sitter))
