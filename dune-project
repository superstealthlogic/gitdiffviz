(lang dune 3.16)

(name git_visualization_diff)

(generate_opam_files true)

(package
 (name git_visualization_diff)
 (synopsis "Typed OCaml backend for git diff visualization scene generation")
 (depends
  ocaml
  dune
  yojson
  cmdliner
  alcotest))
