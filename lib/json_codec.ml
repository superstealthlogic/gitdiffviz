open Diff_types
open Hierarchy_types
open Semantic_types
open Scene_types

module Json = Yojson.Safe

let errorf fmt = Printf.ksprintf (fun message -> Result.error message) fmt

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let required name json =
  match member name json with
  | Some value -> Ok value
  | None -> errorf "missing required field %S" name

let optional name json = member name json

let as_string field = function
  | `String value -> Ok value
  | _ -> errorf "field %S must be a string" field

let as_int field = function
  | `Int value -> Ok value
  | `Intlit value -> (
      match int_of_string_opt value with
      | Some value -> Ok value
      | None -> errorf "field %S must be an integer" field)
  | _ -> errorf "field %S must be an integer" field

let as_bool field = function
  | `Bool value -> Ok value
  | _ -> errorf "field %S must be a boolean" field

let as_list field = function
  | `List values -> Ok values
  | _ -> errorf "field %S must be a list" field

let bind result f = Result.bind result f

let ( let* ) = bind

let map_result f values =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* mapped = f value in
        loop (mapped :: acc) rest
  in
  loop [] values

let required_string name json =
  let* value = required name json in
  as_string name value

let optional_string name json =
  match optional name json with
  | None | Some `Null -> Ok None
  | Some value ->
      let* value = as_string name value in
      Ok (Some value)

let required_int name json =
  let* value = required name json in
  as_int name value

let required_bool name json =
  let* value = required name json in
  as_bool name value

let required_list name json =
  let* value = required name json in
  as_list name value

let option_field name to_yojson = function
  | None -> []
  | Some value -> [ (name, to_yojson value) ]

let revision_comparison_of_yojson json =
  let* base = required_string "base" json in
  let* target = required_string "target" json in
  Ok { base; target }

let revision_comparison_to_yojson (comparison : revision_comparison) =
  `Assoc [ ("base", `String comparison.base); ("target", `String comparison.target) ]

let source_span_of_yojson json =
  let* start_line = required_int "startLine" json in
  let* end_line = required_int "endLine" json in
  Ok { start_line; end_line }

let source_span_to_yojson (span : source_span) =
  `Assoc [ ("startLine", `Int span.start_line); ("endLine", `Int span.end_line) ]

let diff_metrics_to_yojson diff =
  `Assoc
    [
      ("linesAdded", `Int diff.lines_added);
      ("linesRemoved", `Int diff.lines_removed);
      ("changedRatio", `Float diff.changed_ratio);
    ]

let diff_line_range_of_yojson json =
  let* start_line = required_int "startLine" json in
  let* line_count = required_int "lineCount" json in
  Ok { start_line; line_count }

let diff_line_range_to_yojson (range : diff_line_range) =
  `Assoc
    [
      ("startLine", `Int range.start_line);
      ("lineCount", `Int range.line_count);
    ]

let diff_line_of_yojson json =
  let* kind_string = required_string "kind" json in
  let* kind =
    match diff_line_kind_of_string kind_string with
    | Some kind -> Ok kind
    | None -> errorf "unknown diff line kind %S" kind_string
  in
  let* old_line =
    match optional "oldLine" json with
    | None | Some `Null -> Ok None
    | Some value ->
        let* value = as_int "oldLine" value in
        Ok (Some value)
  in
  let* new_line =
    match optional "newLine" json with
    | None | Some `Null -> Ok None
    | Some value ->
        let* value = as_int "newLine" value in
        Ok (Some value)
  in
  let* content = required_string "content" json in
  Ok { kind; old_line; new_line; content }

let diff_line_to_yojson (line : diff_line) =
  `Assoc
    ([
       ("kind", `String (diff_line_kind_to_string line.kind));
       ("content", `String line.content);
     ]
    @ option_field "oldLine" (fun value -> `Int value) line.old_line
    @ option_field "newLine" (fun value -> `Int value) line.new_line)

let diff_hunk_of_yojson json =
  let* old_range_json = required "oldRange" json in
  let* new_range_json = required "newRange" json in
  let* old_range = diff_line_range_of_yojson old_range_json in
  let* new_range = diff_line_range_of_yojson new_range_json in
  let* header = required_string "header" json in
  let* lines =
    match optional "lines" json with
    | None | Some `Null -> Ok None
    | Some value ->
        let* values = as_list "lines" value in
        let* lines = map_result diff_line_of_yojson values in
        Ok (Some lines)
  in
  Ok { old_range; new_range; header; lines }

let diff_hunk_to_yojson (hunk : diff_hunk) =
  `Assoc
    ([
       ("oldRange", diff_line_range_to_yojson hunk.old_range);
       ("newRange", diff_line_range_to_yojson hunk.new_range);
       ("header", `String hunk.header);
     ]
    @ option_field "lines"
        (fun lines -> `List (List.map diff_line_to_yojson lines))
        hunk.lines)

let diff_file_entry_of_yojson json =
  let* path = required_string "path" json in
  let* old_path = optional_string "oldPath" json in
  let* status = required_string "status" json in
  let status = diff_file_status_of_string status in
  let* additions = required_int "additions" json in
  let* deletions = required_int "deletions" json in
  let* is_binary = required_bool "isBinary" json in
  let* hunk_values = required_list "hunks" json in
  let* hunks = map_result diff_hunk_of_yojson hunk_values in
  Ok { path; old_path; status; additions; deletions; is_binary; hunks }

let diff_file_entry_to_yojson (file : diff_file_entry) =
  `Assoc
    ([
       ("path", `String file.path);
       ("status", `String (diff_file_status_to_string file.status));
       ("additions", `Int file.additions);
       ("deletions", `Int file.deletions);
       ("isBinary", `Bool file.is_binary);
       ("hunks", `List (List.map diff_hunk_to_yojson file.hunks));
     ]
    @ option_field "oldPath" (fun value -> `String value) file.old_path)

let git_diff_summary_of_yojson json =
  let* changed_files = required_int "changedFiles" json in
  let* total_additions = required_int "totalAdditions" json in
  let* total_deletions = required_int "totalDeletions" json in
  Ok { changed_files; total_additions; total_deletions }

let git_diff_summary_to_yojson (summary : git_diff_summary) =
  `Assoc
    [
      ("changedFiles", `Int summary.changed_files);
      ("totalAdditions", `Int summary.total_additions);
      ("totalDeletions", `Int summary.total_deletions);
    ]

let git_diff_document_of_yojson json =
  let* version = required_int "version" json in
  let* repo_root = required_string "repoRoot" json in
  let* comparison_json = required "comparison" json in
  let* comparison = revision_comparison_of_yojson comparison_json in
  let* path_filter = optional_string "pathFilter" json in
  let* file_values = required_list "files" json in
  let* files = map_result diff_file_entry_of_yojson file_values in
  let* summary_json = required "summary" json in
  let* summary = git_diff_summary_of_yojson summary_json in
  Ok { version; repo_root; comparison; path_filter; files; summary }

let git_diff_document_to_yojson (document : git_diff_document) =
  `Assoc
    ([
       ("version", `Int document.version);
       ("repoRoot", `String document.repo_root);
       ("comparison", revision_comparison_to_yojson document.comparison);
       ("files", `List (List.map diff_file_entry_to_yojson document.files));
       ("summary", git_diff_summary_to_yojson document.summary);
     ]
    @ option_field "pathFilter" (fun value -> `String value) document.path_filter)

let diff_line_change_to_yojson (change : diff_line_change) =
  `Assoc
    [
      ("kind", `String (diff_line_change_kind_to_string change.kind));
      ("startLine", `Int change.start_line);
      ("lineCount", `Int change.line_count);
    ]

let repository_node_kind_to_yojson kind =
  `String (repository_node_kind_to_string kind)

let repository_hierarchy_node_to_yojson (node : repository_hierarchy_node) =
  `Assoc
    ([
       ("id", `String node.id);
       ("kind", repository_node_kind_to_yojson node.kind);
       ("name", `String node.name);
       ("path", `String node.path);
       ("children", `List (List.map (fun value -> `String value) node.children));
       ("depth", `Int node.depth);
       ("lineCount", `Int node.line_count);
       ("diff", diff_metrics_to_yojson node.diff);
     ]
    @ option_field "parentId" (fun value -> `String value) node.parent_id
    @ option_field "language" (fun value -> `String value) node.language
    @ option_field "status"
        (fun value -> `String (diff_file_status_to_string value))
        node.status
    @ option_field "oldPath" (fun value -> `String value) node.old_path
    @ option_field "lineChanges"
        (fun changes -> `List (List.map diff_line_change_to_yojson changes))
        node.line_changes
    @ option_field "hunks"
        (fun hunks -> `List (List.map diff_hunk_to_yojson hunks))
        node.hunks)

let repository_hierarchy_metrics_to_yojson
    (metrics : repository_hierarchy_metrics) =
  `Assoc
    [
      ("totalNodes", `Int metrics.total_nodes);
      ("totalFiles", `Int metrics.total_files);
      ("changedFiles", `Int metrics.changed_files);
      ("totalAddedLines", `Int metrics.total_added_lines);
      ("totalRemovedLines", `Int metrics.total_removed_lines);
    ]

let repository_hierarchy_document_to_yojson
    (document : repository_hierarchy_document) =
  `Assoc
    ([
       ("version", `Int document.version);
       ("repoRoot", `String document.repo_root);
       ("comparison", revision_comparison_to_yojson document.comparison);
       ( "nodes",
         `List (List.map repository_hierarchy_node_to_yojson document.nodes) );
       ("rootNodeId", `String document.root_node_id);
       ("metrics", repository_hierarchy_metrics_to_yojson document.metrics);
     ]
    @ option_field "pathFilter" (fun value -> `String value) document.path_filter)

let semantic_properties_of_yojson json =
  let list_field name =
    match optional name json with
    | None | Some `Null -> Ok []
    | Some value ->
        let* values = as_list name value in
        map_result (as_string name) values
  in
  let* patterns = list_field "patterns" in
  let* paradigms = list_field "paradigms" in
  let* issues = list_field "issues" in
  let* severity =
    match optional "severity" json with
    | None | Some `Null -> Ok None
    | Some value ->
        let* value = as_string "severity" value in
        (match severity_of_string value with
        | Some severity -> Ok (Some severity)
        | None -> errorf "unknown severity %S" value)
  in
  Ok { patterns; paradigms; issues; severity }

let semantic_properties_to_yojson (semantic : semantic_properties) =
  `Assoc
    ([]
    @
    if semantic.patterns = [] then []
    else [ ("patterns", `List (List.map (fun value -> `String value) semantic.patterns)) ]
    @
    if semantic.paradigms = [] then []
    else [ ("paradigms", `List (List.map (fun value -> `String value) semantic.paradigms)) ]
    @
    if semantic.issues = [] then []
    else [ ("issues", `List (List.map (fun value -> `String value) semantic.issues)) ]
    @ option_field "severity"
        (fun severity -> `String (severity_to_string severity))
        semantic.severity)

let semantic_properties_field (semantic : semantic_properties) =
  match semantic_properties_to_yojson semantic with
  | `Assoc [] -> []
  | json -> [ ("semantic", json) ]

let semantic_symbol_of_yojson json =
  let* id = required_string "id" json in
  let* kind_string = required_string "kind" json in
  let* kind =
    match semantic_symbol_kind_of_string kind_string with
    | Some kind -> Ok kind
    | None -> errorf "unknown semantic symbol kind %S" kind_string
  in
  let* language_kind = optional_string "languageKind" json in
  let* name = required_string "name" json in
  let* span_json = required "span" json in
  let* span = source_span_of_yojson span_json in
  let* parent_symbol_id = optional_string "parentSymbolId" json in
  let* semantic = semantic_properties_of_yojson json in
  Ok { id; kind; language_kind; name; span; parent_symbol_id; semantic }

let semantic_symbol_to_yojson (symbol : semantic_symbol) =
  `Assoc
    ([
       ("id", `String symbol.id);
       ("kind", `String (semantic_symbol_kind_to_string symbol.kind));
       ("name", `String symbol.name);
       ("span", source_span_to_yojson symbol.span);
     ]
    @ option_field "languageKind" (fun value -> `String value) symbol.language_kind
    @ option_field "parentSymbolId" (fun value -> `String value) symbol.parent_symbol_id
    @
    match semantic_properties_to_yojson symbol.semantic with
    | `Assoc fields -> fields
    | _ -> [])

let semantic_file_analysis_of_yojson json =
  let* path = required_string "path" json in
  let* language = required_string "language" json in
  let* symbol_values = required_list "symbols" json in
  let* symbols = map_result semantic_symbol_of_yojson symbol_values in
  Ok { path; language; symbols }

let semantic_file_analysis_to_yojson (file : semantic_file_analysis) =
  `Assoc
    [
      ("path", `String file.path);
      ("language", `String file.language);
      ("symbols", `List (List.map semantic_symbol_to_yojson file.symbols));
    ]

let semantic_input_document_of_yojson json =
  let* version = required_int "version" json in
  let* repo_root = required_string "repoRoot" json in
  let* file_values = required_list "files" json in
  let* files = map_result semantic_file_analysis_of_yojson file_values in
  Ok { version; repo_root; files }

let semantic_input_document_to_yojson (document : semantic_input_document) =
  `Assoc
    [
      ("version", `Int document.version);
      ("repoRoot", `String document.repo_root);
      ("files", `List (List.map semantic_file_analysis_to_yojson document.files));
    ]

let semantic_hierarchy_node_kind_to_yojson kind =
  `String (semantic_hierarchy_node_kind_to_string kind)

let semantic_hierarchy_node_to_yojson (node : semantic_hierarchy_node) =
  `Assoc
    ([
       ("id", `String node.id);
       ("kind", semantic_hierarchy_node_kind_to_yojson node.kind);
       ("name", `String node.name);
       ("path", `String node.path);
       ("children", `List (List.map (fun value -> `String value) node.children));
       ("depth", `Int node.depth);
       ("lineCount", `Int node.line_count);
       ("diff", diff_metrics_to_yojson node.diff);
     ]
    @ option_field "parentId" (fun value -> `String value) node.parent_id
    @ option_field "language" (fun value -> `String value) node.language
    @ option_field "languageKind" (fun value -> `String value) node.language_kind
    @ option_field "span" source_span_to_yojson node.span
    @ option_field "status"
        (fun value -> `String (diff_file_status_to_string value))
        node.status
    @ option_field "oldPath" (fun value -> `String value) node.old_path
    @ option_field "lineChanges"
        (fun changes -> `List (List.map diff_line_change_to_yojson changes))
        node.line_changes
    @ option_field "hunks"
        (fun hunks -> `List (List.map diff_hunk_to_yojson hunks))
        node.hunks
    @ semantic_properties_field node.semantic
    @ option_field "sourceSymbolId" (fun value -> `String value) node.source_symbol_id)

let semantic_hierarchy_metrics_to_yojson metrics =
  `Assoc
    [
      ("totalNodes", `Int metrics.total_nodes);
      ("totalFiles", `Int metrics.total_files);
      ("symbolNodes", `Int metrics.symbol_nodes);
      ("changedFiles", `Int metrics.changed_files);
      ("totalAddedLines", `Int metrics.total_added_lines);
      ("totalRemovedLines", `Int metrics.total_removed_lines);
    ]

let semantic_hierarchy_document_to_yojson
    (document : semantic_hierarchy_document) =
  `Assoc
    ([
       ("version", `Int document.version);
       ("repoRoot", `String document.repo_root);
       ("comparison", revision_comparison_to_yojson document.comparison);
       ("nodes", `List (List.map semantic_hierarchy_node_to_yojson document.nodes));
       ("rootNodeId", `String document.root_node_id);
       ("metrics", semantic_hierarchy_metrics_to_yojson document.metrics);
     ]
    @ option_field "pathFilter" (fun value -> `String value) document.path_filter)

let render_priority_to_yojson priority =
  `String (render_priority_to_string priority)

let render_hints_to_yojson render =
  `Assoc
    (option_field "normalizedSize" (fun value -> `Float value) render.normalized_size
    @ option_field "baseColor" (fun value -> `String value) render.base_color
    @ option_field "additionColor" (fun value -> `String value) render.addition_color
    @ option_field "deletionColor" (fun value -> `String value) render.deletion_color
    @ option_field "iconKey" (fun value -> `String value) render.icon_key
    @ option_field "outlineColor" (fun value -> `String value) render.outline_color
    @ option_field "opacity" (fun value -> `Float value) render.opacity
    @ option_field "priority" render_priority_to_yojson render.priority)

let scene_node_to_yojson (node : scene_node) =
  `Assoc
    ([
       ("id", `String node.id);
       ("kind", `String (visualization_node_kind_to_string node.kind));
       ("name", `String node.name);
     ]
    @ option_field "parentId" (fun value -> `String value) node.parent_id
    @ option_field "path" (fun value -> `String value) node.path
    @ option_field "language" (fun value -> `String value) node.language
    @ option_field "languageKind" (fun value -> `String value) node.language_kind
    @ option_field "span" source_span_to_yojson node.span
    @ option_field "lineCount" (fun value -> `Int value) node.line_count
    @ option_field "status"
        (fun value -> `String (diff_file_status_to_string value))
        node.status
    @ option_field "oldPath" (fun value -> `String value) node.old_path
    @ option_field "diff" diff_metrics_to_yojson node.diff
    @ option_field "lineChanges"
        (fun changes -> `List (List.map diff_line_change_to_yojson changes))
        node.line_changes
    @ option_field "hunks"
        (fun hunks -> `List (List.map diff_hunk_to_yojson hunks))
        node.hunks
    @ semantic_properties_field node.semantic
    @ option_field "render" render_hints_to_yojson node.render)

let scene_edge_to_yojson edge =
  `Assoc
    ([
       ("id", `String edge.id);
       ("kind", `String (visualization_edge_kind_to_string edge.kind));
       ("from", `String edge.from_id);
       ("to", `String edge.to_id);
     ]
    @ option_field "label" (fun value -> `String value) edge.label)

let scene_asset_to_yojson (asset : scene_asset) =
  `Assoc
    [
      ("key", `String asset.key);
      ("type", `String asset.asset_type);
      ("path", `String asset.path);
    ]

let scene_legend_entry_to_yojson entry =
  `Assoc
    ([
       ("key", `String entry.key);
       ("label", `String entry.label);
     ]
    @ option_field "color" (fun value -> `String value) entry.color
    @ option_field "iconKey" (fun value -> `String value) entry.icon_key)

let visualization_scene_to_yojson scene =
  `Assoc
    [
      ("nodes", `List (List.map scene_node_to_yojson scene.nodes));
      ("edges", `List (List.map scene_edge_to_yojson scene.edges));
      ("assets", `List (List.map scene_asset_to_yojson scene.assets));
      ("legend", `List (List.map scene_legend_entry_to_yojson scene.legend));
    ]

let visualization_metrics_to_yojson metrics =
  `Assoc
    [
      ("totalFiles", `Int metrics.total_files);
      ("changedFiles", `Int metrics.changed_files);
      ("totalAddedLines", `Int metrics.total_added_lines);
      ("totalRemovedLines", `Int metrics.total_removed_lines);
    ]

let visualization_document_to_yojson (document : visualization_document) =
  `Assoc
    [
      ("version", `Int document.version);
      ("repoRoot", `String document.repo_root);
      ("comparison", revision_comparison_to_yojson document.comparison);
      ("scene", visualization_scene_to_yojson document.scene);
      ("metrics", visualization_metrics_to_yojson document.metrics);
    ]

let timeline_step_to_yojson (step : timeline_step) =
  `Assoc
    ([
       ("index", `Int step.index);
       ("base", `String step.base);
       ("target", `String step.target);
       ("label", `String step.label);
       ("document", visualization_document_to_yojson step.document);
     ]
    @ option_field "targetDate" (fun value -> `String value) step.target_date
    @ option_field "targetShortHash" (fun value -> `String value)
        step.target_short_hash)

let timeline_document_to_yojson (document : timeline_document) =
  `Assoc
    [
      ("kind", `String "timeline");
      ("version", `Int document.version);
      ("repoRoot", `String document.repo_root);
      ("base", `String document.base);
      ("target", `String document.target);
      ("steps", `List (List.map timeline_step_to_yojson document.steps));
    ]

let read_json_file path =
  try Ok (Json.from_file path)
  with
  | Sys_error message -> Result.error message
  | Yojson.Json_error message -> Result.error message

let write_json_file path json =
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () ->
        Json.pretty_to_channel channel json;
        output_char channel '\n';
        Ok ())
  with Sys_error message -> Result.error message
