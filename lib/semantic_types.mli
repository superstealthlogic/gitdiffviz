open Diff_types

type semantic_symbol_kind =
  | Type_container
  | Function
  | Symbol

type severity =
  | Info
  | Warning
  | Error

type semantic_properties = {
  patterns : string list;
  paradigms : string list;
  issues : string list;
  severity : severity option;
}

type semantic_symbol = {
  id : string;
  kind : semantic_symbol_kind;
  language_kind : string option;
  name : string;
  span : source_span;
  parent_symbol_id : string option;
  semantic : semantic_properties;
}

type semantic_file_analysis = {
  path : string;
  language : string;
  symbols : semantic_symbol list;
}

type semantic_input_document = {
  version : int;
  repo_root : string;
  files : semantic_file_analysis list;
}

type semantic_hierarchy_node_kind =
  | Semantic_repository
  | Semantic_directory
  | Semantic_file
  | Semantic_symbol of semantic_symbol_kind

type semantic_hierarchy_node = {
  id : string;
  kind : semantic_hierarchy_node_kind;
  name : string;
  path : string;
  parent_id : string option;
  children : string list;
  depth : int;
  line_count : int;
  language : string option;
  language_kind : string option;
  span : source_span option;
  diff : diff_metrics;
  status : diff_file_status option;
  old_path : string option;
  line_changes : diff_line_change list option;
  hunks : diff_hunk list option;
  semantic : semantic_properties;
  source_symbol_id : string option;
}

type semantic_hierarchy_metrics = {
  total_nodes : int;
  total_files : int;
  symbol_nodes : int;
  changed_files : int;
  total_added_lines : int;
  total_removed_lines : int;
}

type semantic_hierarchy_document = {
  version : int;
  repo_root : string;
  comparison : revision_comparison;
  path_filter : string option;
  nodes : semantic_hierarchy_node list;
  root_node_id : string;
  metrics : semantic_hierarchy_metrics;
}

val empty_semantic_properties : semantic_properties
val is_empty_semantic_properties : semantic_properties -> bool
val merge_semantic_properties : semantic_properties -> semantic_properties -> semantic_properties
val semantic_symbol_kind_to_string : semantic_symbol_kind -> string
val semantic_symbol_kind_of_string : string -> semantic_symbol_kind option
val semantic_hierarchy_node_kind_to_string : semantic_hierarchy_node_kind -> string
val severity_to_string : severity -> string
val severity_of_string : string -> severity option
