open Diff_types

module Entry_key = struct
  type t = string * string

  let compare = compare
end

module Entry_map = Map.Make (Entry_key)
module String_set = Set.Make (String)

type raw_git_diff_outputs = {
  name_status : string;
  numstat : string;
  unified_diff : string;
}

type mutable_entry = {
  path : string;
  old_path : string option;
  status : diff_file_status;
  additions : int;
  deletions : int;
  is_binary : bool;
  hunks : diff_hunk list;
}

let strip_git_prefix value =
  if String.equal value "/dev/null" then None
  else if String.length value >= 2 then
    match String.sub value 0 2 with
    | "a/" | "b/" -> Some (String.sub value 2 (String.length value - 2))
    | _ -> Some value
  else Some value

let split_lines text = String.split_on_char '\n' text

let trim_cr value =
  let len = String.length value in
  if len > 0 && Char.equal value.[len - 1] '\r' then String.sub value 0 (len - 1)
  else value

let nonempty_lines text =
  split_lines text
  |> List.map trim_cr
  |> List.filter (fun line -> String.trim line <> "")

let decode_status code =
  if String.length code > 0 && Char.equal code.[0] 'R' then Renamed
  else if String.length code > 0 && Char.equal code.[0] 'C' then Copied
  else
    match code with
    | "M" -> Modified
    | "A" -> Added
    | "D" -> Deleted
    | "T" -> Type_changed
    | "U" -> Unmerged
    | _ -> Unknown

let key old_path new_path = (Option.value old_path ~default:"", Option.value new_path ~default:"")

let create_entry old_path new_path status : mutable_entry =
  {
    path = Option.value new_path ~default:(Option.value old_path ~default:"");
    old_path =
      (match (old_path, new_path) with
      | Some old_path, Some new_path when not (String.equal old_path new_path) ->
          Some old_path
      | _ -> None);
    status;
    additions = 0;
    deletions = 0;
    is_binary = false;
    hunks = [];
  }

let compatible_entry_key entries old_path new_path =
  let target_path = Option.value new_path ~default:(Option.value old_path ~default:"") in
  let target_old_path = Option.value old_path ~default:(Option.value new_path ~default:"") in
  entries |> Entry_map.bindings
  |> List.find_map (fun (entry_key, entry) ->
         let entry_old_path = Option.value entry.old_path ~default:entry.path in
         if String.equal entry.path target_path && String.equal entry_old_path target_old_path then
           Some entry_key
         else None)

let ensure_entry (entries : mutable_entry Entry_map.t) old_path new_path status :
    Entry_key.t * mutable_entry * mutable_entry Entry_map.t =
  let entry_key = key old_path new_path in
  match Entry_map.find_opt entry_key entries with
  | Some entry -> (entry_key, entry, entries)
  | None -> (
      match compatible_entry_key entries old_path new_path with
      | Some existing_key ->
          let entry = Entry_map.find existing_key entries in
          let entry =
            if entry.status = Unknown && status <> Unknown then { entry with status } else entry
          in
          (existing_key, entry, Entry_map.add existing_key entry entries)
      | None ->
          let entry = create_entry old_path new_path status in
          (entry_key, entry, Entry_map.add entry_key entry entries))

let parse_name_status (entries : mutable_entry Entry_map.t) output =
  nonempty_lines output
  |> List.fold_left
       (fun entries line ->
         match String.split_on_char '\t' line with
         | code :: old_path :: new_path :: _ when decode_status code = Renamed || decode_status code = Copied ->
             let _, _, entries =
               ensure_entry entries (Some old_path) (Some new_path) (decode_status code)
             in
             entries
         | code :: file_path :: _ ->
             let status = decode_status code in
             let old_path = if status = Added then None else Some file_path in
             let new_path = if status = Deleted then None else Some file_path in
             let _, _, entries = ensure_entry entries old_path new_path status in
             entries
         | _ -> entries)
       entries

let parse_int_or_zero value =
  match int_of_string_opt value with Some value -> value | None -> 0

let parse_numstat (entries : mutable_entry Entry_map.t) output =
  nonempty_lines output
  |> List.fold_left
       (fun entries line ->
         match String.split_on_char '\t' line with
         | additions_raw :: deletions_raw :: path_a :: path_b :: _ ->
             let is_binary = String.equal additions_raw "-" || String.equal deletions_raw "-" in
             let additions = if is_binary then 0 else parse_int_or_zero additions_raw in
             let deletions = if is_binary then 0 else parse_int_or_zero deletions_raw in
             let key, entry, entries = ensure_entry entries (Some path_a) (Some path_b) Unknown in
             Entry_map.add key { entry with additions; deletions; is_binary } entries
         | additions_raw :: deletions_raw :: path :: _ ->
             let is_binary = String.equal additions_raw "-" || String.equal deletions_raw "-" in
             let additions = if is_binary then 0 else parse_int_or_zero additions_raw in
             let deletions = if is_binary then 0 else parse_int_or_zero deletions_raw in
             let key, entry, entries = ensure_entry entries (Some path) (Some path) Unknown in
             Entry_map.add key { entry with additions; deletions; is_binary } entries
         | _ -> entries)
       entries

let starts_with prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.equal (String.sub value 0 prefix_len) prefix

let parse_range_token prefix token =
  if not (starts_with prefix token) then None
  else
    let rest =
      String.sub token (String.length prefix) (String.length token - String.length prefix)
    in
    let start_text, count_text =
      match String.index_opt rest ',' with
      | None -> (rest, None)
      | Some comma ->
          ( String.sub rest 0 comma,
            Some (String.sub rest (comma + 1) (String.length rest - comma - 1)) )
    in
    match int_of_string_opt start_text with
    | None -> None
    | Some start_line ->
        let line_count =
          match count_text with
          | None -> 1
          | Some text -> Option.value (int_of_string_opt text) ~default:1
        in
        Some { start_line; line_count }

let parse_hunk_header line =
  match String.split_on_char ' ' line with
  | "@@" :: old_token :: new_token :: _ -> (
      match (parse_range_token "-" old_token, parse_range_token "+" new_token) with
      | Some old_range, Some new_range ->
          Some { old_range; new_range; header = line; lines = Some [] }
      | _ -> None)
  | _ -> None

let create_diff_line raw_line old_line new_line =
  if String.length raw_line = 0 then None
  else
    let content = String.sub raw_line 1 (String.length raw_line - 1) in
    match raw_line.[0] with
    | '+' -> Some ({ kind = Addition; old_line = None; new_line = Some new_line; content }, old_line, new_line + 1)
    | '-' -> Some ({ kind = Deletion; old_line = Some old_line; new_line = None; content }, old_line + 1, new_line)
    | ' ' ->
        Some
          ( { kind = Context; old_line = Some old_line; new_line = Some new_line; content },
            old_line + 1,
            new_line + 1 )
    | _ -> None

let set_hunks entry hunks = { entry with hunks = List.rev hunks }

let parse_unified_diff (entries : mutable_entry Entry_map.t) output =
  let finish_current entries current_key current_hunks =
    match current_key with
    | None -> entries
    | Some key -> (
        match Entry_map.find_opt key entries with
        | None -> entries
        | Some entry -> Entry_map.add key (set_hunks entry current_hunks) entries)
  in
  let lines = split_lines output |> List.map trim_cr in
  let rec loop entries current_key current_hunks current_hunk old_line new_line = function
    | [] ->
        let current_hunks =
          match current_hunk with None -> current_hunks | Some hunk -> hunk :: current_hunks
        in
        finish_current entries current_key current_hunks
    | line :: rest ->
        if starts_with "diff --git " line then
          let entries = finish_current entries current_key (match current_hunk with None -> current_hunks | Some h -> h :: current_hunks) in
          let prefix = "diff --git a/" in
          let parsed =
            if starts_with prefix line then
              let remaining = String.sub line (String.length prefix) (String.length line - String.length prefix) in
              match String.index_opt remaining ' ' with
              | None -> None
              | Some space ->
                  let old_path = String.sub remaining 0 space in
                  let b_path = String.sub remaining (space + 1) (String.length remaining - space - 1) in
                  let new_path =
                    if starts_with "b/" b_path then String.sub b_path 2 (String.length b_path - 2) else b_path
                  in
                  Some (old_path, new_path)
            else None
          in
          (match parsed with
          | None -> loop entries None [] None 0 0 rest
          | Some (old_path, new_path) ->
              let key, _, entries = ensure_entry entries (Some old_path) (Some new_path) Unknown in
              loop entries (Some key) [] None 0 0 rest)
        else
          match current_key with
          | None -> loop entries current_key current_hunks current_hunk old_line new_line rest
          | Some key -> (
              let update_entry f entries =
                match Entry_map.find_opt key entries with
                | None -> entries
                | Some entry -> Entry_map.add key (f entry) entries
              in
              if starts_with "rename from " line then
                let old_path = String.sub line 12 (String.length line - 12) |> String.trim in
                let entries = update_entry (fun entry -> { entry with old_path = Some old_path }) entries in
                loop entries current_key current_hunks current_hunk old_line new_line rest
              else if starts_with "rename to " line then
                let path = String.sub line 10 (String.length line - 10) |> String.trim in
                let entries = update_entry (fun entry -> { entry with path }) entries in
                loop entries current_key current_hunks current_hunk old_line new_line rest
              else if starts_with "--- " line then
                let entries =
                  match strip_git_prefix (String.sub line 4 (String.length line - 4) |> String.trim) with
                  | None -> entries
                  | Some old_path -> update_entry (fun entry -> { entry with old_path = Some old_path }) entries
                in
                loop entries current_key current_hunks current_hunk old_line new_line rest
              else if starts_with "+++ " line then
                let entries =
                  match strip_git_prefix (String.sub line 4 (String.length line - 4) |> String.trim) with
                  | None -> entries
                  | Some path -> update_entry (fun entry -> { entry with path }) entries
                in
                loop entries current_key current_hunks current_hunk old_line new_line rest
              else if starts_with "@@ " line then
                let current_hunks =
                  match current_hunk with None -> current_hunks | Some hunk -> hunk :: current_hunks
                in
                (match parse_hunk_header line with
                | None -> loop entries current_key current_hunks None old_line new_line rest
                | Some hunk ->
                    loop entries current_key current_hunks (Some hunk) hunk.old_range.start_line
                      hunk.new_range.start_line rest)
              else
                match current_hunk with
                | None -> loop entries current_key current_hunks current_hunk old_line new_line rest
                | Some hunk ->
                    if String.equal line "" || starts_with "\\ No newline" line then
                      loop entries current_key current_hunks current_hunk old_line new_line rest
                    else
                      match create_diff_line line old_line new_line with
                      | None -> loop entries current_key current_hunks current_hunk old_line new_line rest
                      | Some (diff_line, old_line, new_line) ->
                          let lines =
                            match hunk.lines with
                            | None -> [ diff_line ]
                            | Some lines -> lines @ [ diff_line ]
                          in
                          loop entries current_key current_hunks
                            (Some { hunk with lines = Some lines })
                            old_line new_line rest)
  in
  loop entries None [] None 0 0 lines

let canonical_key entry =
  match entry.status with
  | Renamed | Copied ->
      Printf.sprintf "%s:%s->%s" (diff_file_status_to_string entry.status)
        (Option.value entry.old_path ~default:"") entry.path
  | Deleted -> "deleted:" ^ entry.path
  | Added -> "added:" ^ entry.path
  | _ -> "path:" ^ entry.path

let merge_entries (entries : mutable_entry list) : mutable_entry list =
  let table = Hashtbl.create 16 in
  let merge_one entry =
    let key = canonical_key entry in
    match Hashtbl.find_opt table key with
    | None -> Hashtbl.add table key entry
    | Some existing ->
        let seen = existing.hunks |> List.map (fun hunk -> hunk.header) |> String_set.of_list in
        let hunks =
          existing.hunks
          @ List.filter (fun hunk -> not (String_set.mem hunk.header seen)) entry.hunks
        in
        Hashtbl.replace table key
          {
            existing with
            status = (if existing.status = Unknown && entry.status <> Unknown then entry.status else existing.status);
            old_path = (match existing.old_path with Some _ -> existing.old_path | None -> entry.old_path);
            is_binary = existing.is_binary || entry.is_binary;
            additions = max existing.additions entry.additions;
            deletions = max existing.deletions entry.deletions;
            hunks;
          }
  in
  List.iter merge_one entries;
  Hashtbl.to_seq_values table |> List.of_seq

let immutable_entry (entry : mutable_entry) : diff_file_entry =
  {
    path = entry.path;
    old_path = entry.old_path;
    status = entry.status;
    additions = entry.additions;
    deletions = entry.deletions;
    is_binary = entry.is_binary;
    hunks = entry.hunks;
  }

let build_summary (files : diff_file_entry list) =
  List.fold_left
    (fun summary (file : diff_file_entry) ->
      {
        changed_files = summary.changed_files + 1;
        total_additions = summary.total_additions + file.additions;
        total_deletions = summary.total_deletions + file.deletions;
      })
    { changed_files = 0; total_additions = 0; total_deletions = 0 }
    files

let parse_outputs ~repo_root ~base ~target ~path_filter outputs =
  let entries =
    Entry_map.empty
    |> fun entries -> parse_name_status entries outputs.name_status
    |> fun entries -> parse_numstat entries outputs.numstat
    |> fun entries -> parse_unified_diff entries outputs.unified_diff
  in
  let files =
    entries |> Entry_map.bindings |> List.map snd |> merge_entries |> List.map immutable_entry
    |> List.sort (fun (left : diff_file_entry) (right : diff_file_entry) ->
           String.compare left.path right.path)
  in
  {
    version = 1;
    repo_root;
    comparison = { base; target };
    path_filter;
    files;
    summary = build_summary files;
  }

let run_git_capture _repo_root args =
  let command = "git" in
  let argv = Array.of_list (command :: args) in
  let channel = Unix.open_process_args_in command argv in
  let buffer = Buffer.create 4096 in
  (try
     while true do
       Buffer.add_string buffer (input_line channel);
       Buffer.add_char buffer '\n'
     done
   with End_of_file -> ());
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> Ok (Buffer.contents buffer)
  | Unix.WEXITED code -> Error (Printf.sprintf "git exited with status %d" code)
  | Unix.WSIGNALED signal -> Error (Printf.sprintf "git was signaled: %d" signal)
  | Unix.WSTOPPED signal -> Error (Printf.sprintf "git was stopped: %d" signal)

let with_chdir dir f =
  let old = Sys.getcwd () in
  Fun.protect ~finally:(fun () -> Sys.chdir old) (fun () -> Sys.chdir dir; f ())

let resolve_git_root repo_root =
  with_chdir repo_root (fun () -> run_git_capture repo_root [ "rev-parse"; "--show-toplevel" ])
  |> Result.map String.trim

let git_diff_args base target path_filter =
  let base_args = [ base; target ] in
  match path_filter with None -> base_args | Some path_filter -> base_args @ [ "--"; path_filter ]

let extract ~repo_root ~base ~target ~path_filter =
  let absolute_repo_root =
    if Filename.is_relative repo_root then Filename.concat (Sys.getcwd ()) repo_root else repo_root
  in
  match resolve_git_root absolute_repo_root with
  | Error message -> Error message
  | Ok git_root ->
      with_chdir git_root (fun () ->
          let diff_args = git_diff_args base target path_filter in
          match
            ( run_git_capture git_root ([ "diff"; "--name-status"; "--find-renames" ] @ diff_args),
              run_git_capture git_root ([ "diff"; "--numstat"; "--find-renames" ] @ diff_args),
              run_git_capture git_root ([ "diff"; "--unified=3"; "--find-renames"; "--no-color" ] @ diff_args) )
          with
          | Ok name_status, Ok numstat, Ok unified_diff ->
              Ok
                (parse_outputs ~repo_root:git_root ~base ~target ~path_filter
                   { name_status; numstat; unified_diff })
          | Error message, _, _ | _, Error message, _ | _, _, Error message -> Error message)
