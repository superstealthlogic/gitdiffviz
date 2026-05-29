open Diff_types
open Hierarchy_types

module String_map = Map.Make (String)
module String_set = Set.Make (String)

let split_path path =
  path
  |> String.split_on_char '/'
  |> List.filter (fun part -> part <> "")

let path_depth path = List.length (split_path path)

let dirname path =
  match List.rev (split_path path) with
  | [] | [ _ ] -> ""
  | _base :: rest -> String.concat "/" (List.rev rest)

let basename path =
  match List.rev (split_path path) with
  | [] -> path
  | base :: _ -> base

let directory_id path = if path = "" then "repo" else "dir:" ^ path
let file_id path = "file:" ^ path

let compute_changed_ratio lines_added lines_removed line_count =
  let total_changed = lines_added + lines_removed in
  if line_count <= 0 then if total_changed > 0 then 1.0 else 0.0
  else Float.of_int total_changed /. Float.of_int line_count

let count_lines repo_root path status =
  match status with
  | Deleted -> 0
  | _ ->
      let full_path = Filename.concat repo_root path in
      if Sys.file_exists full_path && not (Sys.is_directory full_path) then
        let channel = open_in_bin full_path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
            let rec loop count =
              match input_line channel with
              | _ -> loop (count + 1)
              | exception End_of_file -> count
            in
            loop 0)
      else 0

let empty_diff = { lines_added = 0; lines_removed = 0; changed_ratio = 0.0 }

let make_directory repo_root_name path =
  let id = directory_id path in
  let parent_path = dirname path in
  {
    id;
    kind = if path = "" then Repository else Directory;
    name = if path = "" then repo_root_name else basename path;
    path;
    parent_id = (if path = "" then None else Some (directory_id parent_path));
    children = [];
    depth = path_depth path;
    line_count = 0;
    language = None;
    diff = empty_diff;
    status = None;
    old_path = None;
    line_changes = None;
    hunks = None;
  }

let add_child parent_id child_id nodes =
  match String_map.find_opt parent_id nodes with
  | None -> nodes
  | Some parent ->
      let children =
        if List.mem child_id parent.children then parent.children
        else child_id :: parent.children
      in
      String_map.add parent_id { parent with children } nodes

let ensure_directory repo_root_name path nodes =
  let rec ensure path nodes =
    let id = directory_id path in
    if String_map.mem id nodes then nodes
    else
      let parent_path = dirname path in
      let nodes = if path = "" then nodes else ensure parent_path nodes in
      let nodes = String_map.add id (make_directory repo_root_name path) nodes in
      if path = "" then nodes else add_child (directory_id parent_path) id nodes
  in
  ensure path nodes

let line_changes_for_added_or_deleted (file : diff_file_entry) =
  match file.status with
  | Added ->
      Some
        [
          {
            kind = Line_addition;
            start_line = 1;
            line_count = max 1 file.additions;
          };
        ]
  | Deleted ->
      Some
        [
          {
            kind = Line_deletion;
            start_line = 1;
            line_count = max 1 file.deletions;
          };
        ]
  | _ -> None

let line_changes_from_hunks (hunks : diff_hunk list) =
  let extend (pending : diff_line_change option) (changes : diff_line_change list)
      kind start_line =
    match pending with
    | Some last
      when last.kind = kind && last.start_line + last.line_count = start_line ->
        let updated = { last with line_count = last.line_count + 1 } in
        (Some updated, updated :: List.tl changes)
    | _ ->
        let change = { kind; start_line; line_count = 1 } in
        (Some change, change :: changes)
  in
  let _, changes =
    List.fold_left
      (fun (pending, changes) hunk ->
        match hunk.lines with
        | None -> (pending, changes)
        | Some lines ->
            List.fold_left
              (fun (pending, changes) (line : diff_line) ->
                match (line.kind, line.old_line, line.new_line) with
                | Addition, _, Some new_line ->
                    extend pending changes Line_addition new_line
                | Deletion, Some old_line, _ ->
                    extend pending changes Line_deletion old_line
                | _ -> (None, changes))
              (pending, changes) lines)
      (None, []) hunks
  in
  match List.rev changes with
  | [] -> None
  | changes -> Some changes

let line_changes_for_file (file : diff_file_entry) =
  match line_changes_for_added_or_deleted file with
  | Some changes -> Some changes
  | None -> line_changes_from_hunks file.hunks

let add_file repo_root_name repo_root nodes (file : diff_file_entry) =
  let directory_path = dirname file.path in
  let nodes = ensure_directory repo_root_name directory_path nodes in
  let parent_id = directory_id directory_path in
  let current_line_count = count_lines repo_root file.path file.status in
  let line_count =
    match file.status with
    | Deleted -> file.deletions
    | _ -> max current_line_count file.additions
  in
  let id = file_id file.path in
  let node =
    {
      id;
      kind = File;
      name = basename file.path;
      path = file.path;
      parent_id = Some parent_id;
      children = [];
      depth = path_depth file.path;
      line_count;
      language = Some (Language.detect_by_path file.path);
      status = Some file.status;
      old_path = file.old_path;
      diff =
        {
          lines_added = file.additions;
          lines_removed = file.deletions;
          changed_ratio =
            compute_changed_ratio file.additions file.deletions line_count;
        };
      line_changes = line_changes_for_file file;
      hunks = Some file.hunks;
    }
  in
  nodes |> String_map.add id node |> add_child parent_id id

let aggregate nodes =
  let node_ids_by_depth =
    nodes
    |> String_map.bindings
    |> List.map snd
    |> List.sort (fun left right -> compare right.depth left.depth)
    |> List.map (fun node -> node.id)
  in
  List.fold_left
    (fun nodes node_id ->
      let node = String_map.find node_id nodes in
      match node.parent_id with
      | None -> nodes
      | Some parent_id -> (
          match String_map.find_opt parent_id nodes with
          | None -> nodes
          | Some parent ->
              let parent =
                {
                  parent with
                  line_count = parent.line_count + node.line_count;
                  diff =
                    {
                      lines_added =
                        parent.diff.lines_added + node.diff.lines_added;
                      lines_removed =
                        parent.diff.lines_removed + node.diff.lines_removed;
                      changed_ratio = 0.0;
                    };
                }
              in
              String_map.add parent_id parent nodes))
    nodes node_ids_by_depth
  |> String_map.map (fun node ->
         let diff =
           {
             node.diff with
             changed_ratio =
               compute_changed_ratio node.diff.lines_added
                 node.diff.lines_removed node.line_count;
           }
         in
         { node with children = List.sort String.compare node.children; diff })

let build (diff_document : git_diff_document) =
  let repo_root_name = basename diff_document.repo_root in
  let nodes =
    String_map.empty
    |> ensure_directory repo_root_name ""
    |> fun nodes ->
    List.fold_left
      (add_file repo_root_name diff_document.repo_root)
      nodes diff_document.files
    |> aggregate
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
  let total_files =
    List.fold_left
      (fun count node -> match node.kind with File -> count + 1 | _ -> count)
      0 node_list
  in
  {
    version = 1;
    repo_root = diff_document.repo_root;
    comparison = diff_document.comparison;
    path_filter = diff_document.path_filter;
    nodes = node_list;
    root_node_id = "repo";
    metrics =
      {
        total_nodes = List.length node_list;
        total_files;
        changed_files = diff_document.summary.changed_files;
        total_added_lines = diff_document.summary.total_additions;
        total_removed_lines = diff_document.summary.total_deletions;
      };
  }
