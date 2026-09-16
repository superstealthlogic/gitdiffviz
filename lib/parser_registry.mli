open Semantic_types

(* Whether a semantic extractor is registered for this path's language. *)
val supports_path : string -> bool

val extract_file :
  repo_root:string ->
  path:string ->
  source:string ->
  (semantic_file_analysis option, string) result
