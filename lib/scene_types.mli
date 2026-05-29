open Diff_types
open Semantic_types

type visualization_node_kind =
  | Scene_repository
  | Scene_directory
  | Scene_file
  | Scene_type_container
  | Scene_symbol
  | Scene_function
  | Scene_pattern_marker
  | Scene_issue_marker

type visualization_edge_kind =
  | Contains
  | Annotates
  | Relates_to
  | Calls

type render_priority =
  | Changed
  | Context

type render_hints = {
  normalized_size : float option;
  base_color : string option;
  addition_color : string option;
  deletion_color : string option;
  icon_key : string option;
  outline_color : string option;
  opacity : float option;
  priority : render_priority option;
}

type scene_node = {
  id : string;
  kind : visualization_node_kind;
  name : string;
  parent_id : string option;
  path : string option;
  language : string option;
  language_kind : string option;
  span : source_span option;
  line_count : int option;
  status : diff_file_status option;
  old_path : string option;
  diff : diff_metrics option;
  line_changes : diff_line_change list option;
  hunks : diff_hunk list option;
  semantic : semantic_properties;
  render : render_hints option;
}

type scene_edge = {
  id : string;
  kind : visualization_edge_kind;
  from_id : string;
  to_id : string;
  label : string option;
}

type scene_asset = {
  key : string;
  asset_type : string;
  path : string;
}

type scene_legend_entry = {
  key : string;
  label : string;
  color : string option;
  icon_key : string option;
}

type visualization_scene = {
  nodes : scene_node list;
  edges : scene_edge list;
  assets : scene_asset list;
  legend : scene_legend_entry list;
}

type visualization_metrics = {
  total_files : int;
  changed_files : int;
  total_added_lines : int;
  total_removed_lines : int;
}

type visualization_document = {
  version : int;
  repo_root : string;
  comparison : revision_comparison;
  scene : visualization_scene;
  metrics : visualization_metrics;
}

val visualization_node_kind_to_string : visualization_node_kind -> string
val visualization_edge_kind_to_string : visualization_edge_kind -> string
val render_priority_to_string : render_priority -> string
