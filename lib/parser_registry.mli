open Semantic_types

val extract_file :
  repo_root:string ->
  path:string ->
  source:string ->
  (semantic_file_analysis option, string) result
