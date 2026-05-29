open Semantic_types

module type S = sig
  val language : string
  val extensions : string list

  val extract :
    repo_root:string ->
    path:string ->
    source:string ->
    (semantic_symbol list, string) result
end
