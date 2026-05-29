open Diff_types
open Hierarchy_types
open Semantic_types

module String_map = Map.Make (String)

let kind_of_repository_kind = function
  | Repository -> Semantic_repository
  | Directory -> Semantic_directory
  | File -> Semantic_file

let from_repository_node (node : repository_hierarchy_node) =
  {
    id = node.id;
    kind = kind_of_repository_kind node.kind;
    name = node.name;
    path = node.path;
    parent_id = node.parent_id;
    children = node.children;
    depth = node.depth;
    line_count = node.line_count;
    language = node.language;
    language_kind = None;
    span = None;
    diff = node.diff;
    status = node.status;
    old_path = node.old_path;
    line_changes = node.line_changes;
    hunks = node.hunks;
    semantic = empty_semantic_properties;
    source_symbol_id = None;
  }

let from_repository_hierarchy (hierarchy : repository_hierarchy_document) =
  {
    version = 1;
    repo_root = hierarchy.repo_root;
    comparison = hierarchy.comparison;
    path_filter = hierarchy.path_filter;
    nodes = List.map from_repository_node hierarchy.nodes;
    root_node_id = hierarchy.root_node_id;
    metrics =
      {
        total_nodes = hierarchy.metrics.total_nodes;
        total_files = hierarchy.metrics.total_files;
        symbol_nodes = 0;
        changed_files = hierarchy.metrics.changed_files;
        total_added_lines = hierarchy.metrics.total_added_lines;
        total_removed_lines = hierarchy.metrics.total_removed_lines;
      };
  }

let overlap_length start_a end_a start_b end_b =
  let start_line = max start_a start_b in
  let end_line = min end_a end_b in
  max 0 (end_line - start_line + 1)

let line_in_span line (span : source_span) =
  line >= span.start_line && line <= span.end_line

let first_current_line_after_deletion lines =
  List.find_map
    (fun (line : diff_line) ->
      match line.new_line with
      | Some new_line when line.kind <> Deletion -> Some new_line
      | _ -> None)
    lines

let first_current_line_before_deletion lines =
  lines |> List.rev
  |> List.find_map (fun (line : diff_line) ->
         match line.new_line with
         | Some new_line when line.kind <> Deletion -> Some new_line
         | _ -> None)

let projected_deletion_line hunk before after =
  match first_current_line_after_deletion after with
  | Some line -> line
  | None -> (
      match first_current_line_before_deletion before with
      | Some line -> line
      | None -> hunk.new_range.start_line)

let count_precise_hunk_overlap hunks (span : source_span) =
  let additions = ref 0 in
  let deletions = ref 0 in
  let count_line hunk before after (line : diff_line) =
    match line.kind with
    | Context -> ()
    | Addition -> (
        match line.new_line with
        | Some new_line when line_in_span new_line span -> incr additions
        | _ -> ())
    | Deletion ->
        let projected_line = projected_deletion_line hunk before after in
        if line_in_span projected_line span then incr deletions
  in
  let count_hunk (hunk : diff_hunk) =
    match hunk.lines with
    | None -> ()
    | Some lines ->
        let rec loop before = function
          | [] -> ()
          | line :: after ->
              count_line hunk before after line;
              loop (line :: before) after
        in
        loop [] lines
  in
  List.iter count_hunk hunks;
  if !additions > 0 || !deletions > 0 then Some (!additions, !deletions)
  else None

let count_line_change_overlap line_changes (span : source_span) =
  let additions = ref 0 in
  let deletions = ref 0 in
  let count_change (change : diff_line_change) =
    let overlap =
      overlap_length span.start_line span.end_line change.start_line
        (change.start_line + change.line_count - 1)
    in
    match change.kind with
    | Line_addition -> additions := !additions + overlap
    | Line_deletion -> deletions := !deletions + overlap
  in
  List.iter count_change line_changes;
  if !additions > 0 || !deletions > 0 then Some (!additions, !deletions)
  else None

let count_hunk_range_overlap hunks (span : source_span) =
  let additions = ref 0 in
  let deletions = ref 0 in
    let count_hunk (hunk : diff_hunk) =
      let new_overlap =
        overlap_length span.start_line span.end_line hunk.new_range.start_line
          (hunk.new_range.start_line + max hunk.new_range.line_count 1 - 1)
      in
      let deletion_anchor =
        if hunk.new_range.line_count = 0 then hunk.new_range.start_line
        else hunk.new_range.start_line
      in
      let old_overlap =
        overlap_length span.start_line span.end_line deletion_anchor
          (deletion_anchor + max hunk.old_range.line_count 1 - 1)
      in
      additions := !additions + new_overlap;
      deletions := !deletions + old_overlap
    in
    List.iter count_hunk hunks;
    (!additions, !deletions)

let count_hunk_overlap file_node (span : source_span) =
  match file_node.hunks with
  | Some hunks -> (
      match count_precise_hunk_overlap hunks span with
      | Some counts -> counts
      | None -> (
          match file_node.line_changes with
          | Some line_changes -> (
              match count_line_change_overlap line_changes span with
              | Some counts -> counts
              | None -> count_hunk_range_overlap hunks span)
          | None -> count_hunk_range_overlap hunks span))
  | None -> (
      match file_node.line_changes with
      | Some line_changes -> (
          match count_line_change_overlap line_changes span with
          | Some counts -> counts
          | None -> (0, 0))
      | None -> (0, 0))

let changed_ratio lines_added lines_removed line_count =
  let total = lines_added + lines_removed in
  if line_count <= 0 then if total > 0 then 1.0 else 0.0
  else Float.of_int total /. Float.of_int line_count

let symbol_node_id file_path (symbol : semantic_symbol) =
  "symbol:" ^ file_path ^ ":" ^ symbol.id

let symbol_line_count span = max 0 (span.end_line - span.start_line + 1)

let add_child parent_id child_id nodes =
  match String_map.find_opt parent_id nodes with
  | None -> nodes
  | Some parent ->
      let children =
        if List.mem child_id parent.children then parent.children
        else parent.children @ [ child_id ]
      in
      String_map.add parent_id { parent with children } nodes

let merge_semantic node semantic =
  { node with semantic = merge_semantic_properties node.semantic semantic }

let bubble_semantic nodes start_id semantic =
  let rec loop nodes current_id =
    match String_map.find_opt current_id nodes with
    | None -> nodes
    | Some node ->
        let nodes = String_map.add current_id (merge_semantic node semantic) nodes in
        (match node.parent_id with None -> nodes | Some parent_id -> loop nodes parent_id)
  in
  loop nodes start_id

let build ~diff_document:_ ~hierarchy_document ~semantic_document =
  let base = from_repository_hierarchy hierarchy_document in
  let nodes =
    base.nodes
    |> List.map (fun node -> (node.id, node))
    |> List.to_seq |> String_map.of_seq
  in
  let file_by_path =
    base.nodes
    |> List.filter_map (fun node ->
           match node.kind with
           | Semantic_file -> Some (node.path, node)
           | _ -> None)
    |> List.to_seq |> String_map.of_seq
  in
  let file_by_old_path =
    base.nodes
    |> List.filter_map (fun node ->
           match (node.kind, node.old_path) with
           | Semantic_file, Some old_path -> Some (old_path, node)
           | _ -> None)
    |> List.to_seq |> String_map.of_seq
  in
  let find_file_node path =
    match String_map.find_opt path file_by_path with
    | Some file_node -> Some file_node
    | None -> String_map.find_opt path file_by_old_path
  in
  let symbol_nodes = ref 0 in
  let nodes =
    List.fold_left
      (fun nodes (file_analysis : semantic_file_analysis) ->
        match find_file_node file_analysis.path with
        | None -> nodes
        | Some file_node ->
            let sorted_symbols =
              List.sort
                (fun (left : semantic_symbol) (right : semantic_symbol) ->
                  match compare left.span.start_line right.span.start_line with
                  | 0 -> (
                      match compare right.span.end_line left.span.end_line with
                      | 0 -> String.compare left.name right.name
                      | value -> value)
                  | value -> value)
                file_analysis.symbols
            in
            let symbol_ids =
              sorted_symbols
              |> List.map (fun (symbol : semantic_symbol) ->
                     (symbol.id, symbol_node_id file_node.path symbol))
              |> List.to_seq |> String_map.of_seq
            in
            List.fold_left
              (fun nodes (symbol : semantic_symbol) ->
                let id = String_map.find symbol.id symbol_ids in
                let parent_id =
                  match symbol.parent_symbol_id with
                  | Some parent_symbol_id -> (
                      match String_map.find_opt parent_symbol_id symbol_ids with
                      | Some parent_id -> parent_id
                      | None -> file_node.id)
                  | None -> file_node.id
                in
                let parent_node =
                  match String_map.find_opt parent_id nodes with
                  | Some node -> node
                  | None -> file_node
                in
                let additions, deletions = count_hunk_overlap file_node symbol.span in
                let line_count = symbol_line_count symbol.span in
                let node =
                  {
                    id;
                    kind = Semantic_symbol symbol.kind;
                    name = symbol.name;
                    path = file_node.path;
                    parent_id = Some parent_id;
                    children = [];
                    depth = parent_node.depth + 1;
                    line_count;
                    language = Some file_analysis.language;
                    language_kind = symbol.language_kind;
                    span = Some symbol.span;
                    diff =
                      {
                        lines_added = additions;
                        lines_removed = deletions;
                        changed_ratio = changed_ratio additions deletions line_count;
                      };
                    status = file_node.status;
                    old_path = file_node.old_path;
                    line_changes = None;
                    hunks = None;
                    semantic = symbol.semantic;
                    source_symbol_id = Some symbol.id;
                  }
                in
                incr symbol_nodes;
                let nodes = nodes |> String_map.add id node |> add_child parent_id id in
                bubble_semantic nodes file_node.id symbol.semantic)
              nodes sorted_symbols)
      nodes semantic_document.files
  in
  let nodes =
    String_map.map
      (fun node -> { node with children = List.sort String.compare node.children })
      nodes
  in
  let node_list =
    nodes
    |> String_map.bindings
    |> List.map snd
    |> List.sort (fun left right ->
           match String.compare left.path right.path with
           | 0 -> (
               match compare left.depth right.depth with
               | 0 -> String.compare left.id right.id
               | value -> value)
           | value -> value)
  in
  {
    base with
    nodes = node_list;
    metrics =
      {
        base.metrics with
        total_nodes = List.length node_list;
        symbol_nodes = !symbol_nodes;
      };
  }
