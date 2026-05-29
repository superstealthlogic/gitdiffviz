open Diff_types
open Semantic_types
open Scene_types

let scene_kind = function
  | Semantic_repository -> Scene_repository
  | Semantic_directory -> Scene_directory
  | Semantic_file -> Scene_file
  | Semantic_symbol Type_container -> Scene_type_container
  | Semantic_symbol Function -> Scene_function
  | Semantic_symbol Symbol -> Scene_symbol

let max_line_count (nodes : semantic_hierarchy_node list) =
  List.fold_left
    (fun acc (node : semantic_hierarchy_node) -> max acc node.line_count)
    0 nodes

let normalized_size max_lines line_count =
  if max_lines <= 0 then Some 0.0
  else Some (Float.of_int line_count /. Float.of_int max_lines)

let is_context_node (node : semantic_hierarchy_node) =
  match node.status with
  | Some Unchanged -> true
  | _ ->
      (match node.kind with Semantic_directory -> true | _ -> false)
      && node.diff.lines_added = 0 && node.diff.lines_removed = 0

let render_hints max_lines (node : semantic_hierarchy_node) =
  {
    normalized_size = normalized_size max_lines node.line_count;
    base_color = Some "#64748B";
    addition_color = Some "#22C55E";
    deletion_color = Some "#EF4444";
    icon_key = None;
    outline_color =
      (match (node.status, node.semantic.severity) with
      | Some Added, _ -> Some "#22C55E"
      | Some Deleted, _ -> Some "#EF4444"
      | _, Some Info -> Some "#38BDF8"
      | _, Some Warning -> Some "#F59E0B"
      | _, Some Error -> Some "#EF4444"
      | _ -> None);
    opacity = Some (if is_context_node node then 0.42 else 1.0);
    priority = Some (if is_context_node node then Context else Changed);
  }

let issue_display_name issue =
  issue
  |> String.split_on_char '_'
  |> List.map (fun part ->
         if part = "" then part
         else
           String.uppercase_ascii (String.sub part 0 1)
           ^ String.sub part 1 (String.length part - 1))
  |> String.concat " "

let issue_marker_id node_id issue = "issue:" ^ node_id ^ ":" ^ issue

let scene_node_of_semantic_node max_lines (node : semantic_hierarchy_node) =
  {
    id = node.id;
    kind = scene_kind node.kind;
    name = node.name;
    parent_id = node.parent_id;
    path = Some node.path;
    language = node.language;
    language_kind = node.language_kind;
    span = node.span;
    line_count = Some node.line_count;
    status = node.status;
    old_path = node.old_path;
    diff = Some node.diff;
    line_changes = node.line_changes;
    hunks = node.hunks;
    semantic = node.semantic;
    render = Some (render_hints max_lines node);
  }

let issue_scene_node (node : semantic_hierarchy_node) issue =
  {
    id = issue_marker_id node.id issue;
    kind = Scene_issue_marker;
    name = issue_display_name issue;
    parent_id = Some node.id;
    path = Some node.path;
    language = node.language;
    language_kind = node.language_kind;
    span = node.span;
    line_count = None;
    status = None;
    old_path = None;
    diff = None;
    line_changes = None;
    hunks = None;
    semantic =
      {
        empty_semantic_properties with
        issues = [ issue ];
        severity = node.semantic.severity;
      };
    render =
      Some
        {
          normalized_size = Some 0.08;
          base_color = None;
          addition_color = None;
          deletion_color = None;
          icon_key = None;
          outline_color =
            (match node.semantic.severity with
            | Some Info -> Some "#38BDF8"
            | Some Warning -> Some "#F59E0B"
            | Some Error -> Some "#EF4444"
            | None -> None);
          opacity = None;
          priority = None;
        };
  }

let contains_edge (node : semantic_hierarchy_node) =
  Option.map
    (fun parent_id ->
      {
        id = "contains:" ^ parent_id ^ "->" ^ node.id;
        kind = Contains;
        from_id = parent_id;
        to_id = node.id;
        label = None;
      })
    node.parent_id

let issue_edge (node : semantic_hierarchy_node) issue =
  let issue_id = issue_marker_id node.id issue in
  {
    id = "annotates:" ^ issue_id ^ "->" ^ node.id;
    kind = Annotates;
    from_id = issue_id;
    to_id = node.id;
    label = None;
  }

let legend =
  [
    { key = "addition"; label = "Added lines"; color = Some "#22C55E"; icon_key = None };
    { key = "deletion"; label = "Removed lines"; color = Some "#EF4444"; icon_key = None };
    { key = "unchanged"; label = "Unchanged base"; color = Some "#64748B"; icon_key = None };
    { key = "issue-info"; label = "Info issue"; color = Some "#38BDF8"; icon_key = None };
    { key = "issue-warning"; label = "Warning issue"; color = Some "#F59E0B"; icon_key = None };
    { key = "issue-error"; label = "Error issue"; color = Some "#EF4444"; icon_key = None };
  ]

let build (hierarchy : semantic_hierarchy_document) =
  let max_lines = max_line_count hierarchy.nodes in
  let nodes, edges =
    List.fold_left
      (fun (nodes, edges) node ->
        let base_node = scene_node_of_semantic_node max_lines node in
        let nodes = base_node :: nodes in
        let edges =
          match contains_edge node with None -> edges | Some edge -> edge :: edges
        in
        List.fold_left
          (fun (nodes, edges) issue ->
            (issue_scene_node node issue :: nodes, issue_edge node issue :: edges))
          (nodes, edges) node.semantic.issues)
      ([], []) hierarchy.nodes
  in
  {
    version = 1;
    repo_root = hierarchy.repo_root;
    comparison = hierarchy.comparison;
    scene =
      {
        nodes =
          List.sort
            (fun (left : scene_node) (right : scene_node) ->
              String.compare left.id right.id)
            nodes;
        edges =
          List.sort
            (fun (left : scene_edge) (right : scene_edge) ->
              String.compare left.id right.id)
            edges;
        assets = [];
        legend;
      };
    metrics =
      {
        total_files = hierarchy.metrics.total_files;
        changed_files = hierarchy.metrics.changed_files;
        total_added_lines = hierarchy.metrics.total_added_lines;
        total_removed_lines = hierarchy.metrics.total_removed_lines;
      };
  }
