open Diff_types
open Hierarchy_types
open Semantic_types
open Scene_types

val git_diff_document_of_yojson :
  Yojson.Safe.t -> (git_diff_document, string) result

val git_diff_document_to_yojson : git_diff_document -> Yojson.Safe.t

val repository_hierarchy_document_to_yojson :
  repository_hierarchy_document -> Yojson.Safe.t

val semantic_input_document_of_yojson :
  Yojson.Safe.t -> (semantic_input_document, string) result

val semantic_input_document_to_yojson : semantic_input_document -> Yojson.Safe.t

val semantic_hierarchy_document_to_yojson :
  semantic_hierarchy_document -> Yojson.Safe.t

val visualization_document_to_yojson : visualization_document -> Yojson.Safe.t

val read_json_file : string -> (Yojson.Safe.t, string) result
val write_json_file : string -> Yojson.Safe.t -> (unit, string) result
