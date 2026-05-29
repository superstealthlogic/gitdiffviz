open Semantic_types

val extract :
  repo_root:string ->
  files:string list ->
  (semantic_input_document, string) result
