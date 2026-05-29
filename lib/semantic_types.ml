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

let empty_semantic_properties =
  { patterns = []; paradigms = []; issues = []; severity = None }

let is_empty_semantic_properties semantic =
  semantic.patterns = [] && semantic.paradigms = [] && semantic.issues = []
  && Option.is_none semantic.severity

let merge_unique left right =
  List.fold_left
    (fun acc value -> if List.mem value acc then acc else acc @ [ value ])
    left right

let severity_rank = function
  | Info -> 1
  | Warning -> 2
  | Error -> 3

let merge_severity left right =
  match (left, right) with
  | None, value | value, None -> value
  | Some left, Some right ->
      if severity_rank right > severity_rank left then Some right else Some left

let merge_semantic_properties left right =
  {
    patterns = merge_unique left.patterns right.patterns;
    paradigms = merge_unique left.paradigms right.paradigms;
    issues = merge_unique left.issues right.issues;
    severity = merge_severity left.severity right.severity;
  }

let semantic_symbol_kind_to_string = function
  | Type_container -> "type_container"
  | Function -> "function"
  | Symbol -> "symbol"

let semantic_symbol_kind_of_string = function
  | "type_container" -> Some Type_container
  | "function" -> Some Function
  | "symbol" -> Some Symbol
  | _ -> None

let semantic_hierarchy_node_kind_to_string = function
  | Semantic_repository -> "repository"
  | Semantic_directory -> "directory"
  | Semantic_file -> "file"
  | Semantic_symbol kind -> semantic_symbol_kind_to_string kind

let severity_to_string = function
  | Info -> "info"
  | Warning -> "warning"
  | Error -> "error"

let severity_of_string = function
  | "info" -> Some Info
  | "warning" -> Some Warning
  | "error" -> Some Error
  | _ -> None
