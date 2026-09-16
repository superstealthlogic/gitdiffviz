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
  ; bin/main.ml uses the Cmd.* API introduced in cmdliner 1.1.
  (cmdliner (>= 1.1.0))
  (alcotest :with-test)
  tree-sitter))
