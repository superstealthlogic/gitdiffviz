(* Shared helpers for walking the CST that the OCaml tree-sitter bindings
   produce. The binding node type carries no field names and includes anonymous
   keyword tokens among the children, so name lookup is keyword-relative. *)

open Diff_types

module TS = Tree_sitter_bindings.Tree_sitter_output_t

val lines : string -> string array
val line_at : string array -> int -> string
val substring_safe : string -> int -> int -> string

(* Source text covered by a node, including multi-line spans. *)
val text_of_node : string array -> TS.node -> string
val trimmed_text : string array -> TS.node -> string

val children : TS.node -> TS.node list
val child_types : TS.node -> string list
val has_child_type : string list -> TS.node -> bool
val first_child_of_type : string list -> TS.node -> TS.node option

(* First child with a type in [types] occurring after a child with a type in
   [keywords]. *)
val child_after :
  keywords:string list -> types:string list -> TS.node -> TS.node option

val find_first_of_type : string list -> TS.node -> TS.node option
val exists_descendant : string list -> TS.node -> bool

val node_span : TS.node -> source_span
