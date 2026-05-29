open Diff_types

type repository_node_kind =
  | Repository
  | Directory
  | File

type repository_hierarchy_node = {
  id : string;
  kind : repository_node_kind;
  name : string;
  path : string;
  parent_id : string option;
  children : string list;
  depth : int;
  line_count : int;
  language : string option;
  diff : diff_metrics;
  status : diff_file_status option;
  old_path : string option;
  line_changes : diff_line_change list option;
  hunks : diff_hunk list option;
}

type repository_hierarchy_metrics = {
  total_nodes : int;
  total_files : int;
  changed_files : int;
  total_added_lines : int;
  total_removed_lines : int;
}

type repository_hierarchy_document = {
  version : int;
  repo_root : string;
  comparison : revision_comparison;
  path_filter : string option;
  nodes : repository_hierarchy_node list;
  root_node_id : string;
  metrics : repository_hierarchy_metrics;
}

let repository_node_kind_to_string = function
  | Repository -> "repository"
  | Directory -> "directory"
  | File -> "file"

let repository_node_kind_of_string = function
  | "repository" -> Some Repository
  | "directory" -> Some Directory
  | "file" -> Some File
  | _ -> None
