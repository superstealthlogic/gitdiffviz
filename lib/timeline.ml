open Scene_types

let recognized_semantic_path path =
  match Language.detect_by_path path with
  | "c" | "cpp" | "rust" | "swift" -> true
  | _ -> false

let run_git_capture repo_root args =
  let old = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir old)
    (fun () ->
      Sys.chdir repo_root;
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
      | Unix.WSTOPPED signal -> Error (Printf.sprintf "git was stopped: %d" signal))

let split_lines text =
  text |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")

let resolve_git_root repo_root =
  let absolute_repo_root =
    if Filename.is_relative repo_root then Filename.concat (Sys.getcwd ()) repo_root
    else repo_root
  in
  match run_git_capture absolute_repo_root [ "rev-parse"; "--show-toplevel" ] with
  | Error message -> Error message
  | Ok root -> Ok (String.trim root)

let commits_between ~repo_root ~base ~target =
  match run_git_capture repo_root [ "rev-list"; "--reverse"; base ^ ".." ^ target ] with
  | Error message -> Error message
  | Ok output -> (
      match split_lines output with
      | [] -> Ok [ base; target ]
      | commits -> Ok (base :: commits))

let short_commit commit =
  if String.length commit <= 8 then commit else String.sub commit 0 8

let commit_metadata ~repo_root commit =
  match
    run_git_capture repo_root
      [
        "show";
        "-s";
        "--date=format-local:%Y-%m-%d %H:%M";
        "--format=%h%x09%cs%x09%ad%x09%B";
        commit;
      ]
  with
  | Error _ -> (None, None, None, None)
  | Ok output -> (
      match String.trim output |> String.split_on_char '\t' with
      | short_hash :: date :: timestamp :: message_parts ->
          ( Some short_hash,
            Some date,
            Some timestamp,
            Some (String.concat "\t" message_parts) )
      | _ -> (None, None, None, None))

let pairs commits =
  let rec loop acc = function
    | left :: right :: rest -> loop ((left, right) :: acc) (right :: rest)
    | _ -> List.rev acc
  in
  loop [] commits

let git_show_file ~repo_root ~commit ~path =
  run_git_capture repo_root [ "show"; commit ^ ":" ^ path ]

let semantic_file_at_commit ~repo_root ~commit ~path =
  if not (recognized_semantic_path path) then Ok None
  else
    match git_show_file ~repo_root ~commit ~path with
    | Error _ -> Ok None
    | Ok source -> Parser_registry.extract_file ~repo_root ~path ~source

let semantic_files_for_diff ~repo_root
    (diff_document : Diff_types.git_diff_document) =
  let extract_for_file (file : Diff_types.diff_file_entry) =
    let base_path = Option.value file.old_path ~default:file.path in
    let target_entries =
      match file.status with
      | Diff_types.Deleted -> Ok []
      | _ -> (
          match semantic_file_at_commit ~repo_root ~commit:diff_document.comparison.target
                  ~path:file.path
          with
          | Error message -> Error message
          | Ok None -> Ok []
          | Ok (Some analysis) -> Ok [ analysis ])
    in
    match target_entries with
    | Error message -> Error message
    | Ok target_entries -> (
        match file.status with
        | Diff_types.Added -> Ok target_entries
        | _ -> (
            match
              semantic_file_at_commit ~repo_root ~commit:diff_document.comparison.base
                ~path:base_path
            with
            | Error message -> Error message
            | Ok None -> Ok target_entries
            | Ok (Some analysis) -> Ok (analysis :: target_entries)))
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc |> List.concat)
    | file :: rest -> (
        match extract_for_file file with
        | Error message -> Error message
        | Ok analyses -> loop (analyses :: acc) rest)
  in
  loop [] diff_document.Diff_types.files

let scene_for_diff ?semantic_document (diff_document : Diff_types.git_diff_document) =
  let hierarchy_document = Hierarchy.build diff_document in
  match semantic_document with
  | None -> Semantic_join.from_repository_hierarchy hierarchy_document |> Scene.build
  | Some semantic_document ->
      Semantic_join.build ~diff_document ~hierarchy_document ~semantic_document
      |> Scene.build

let build ~repo_root ~base ~target ~path_filter =
  match resolve_git_root repo_root with
  | Error message -> Error message
  | Ok repo_root -> (
      match commits_between ~repo_root ~base ~target with
      | Error message -> Error message
      | Ok commits ->
          let build_step index (base, target) =
            match Git_diff.extract ~repo_root ~base ~target ~path_filter with
            | Error message -> Error message
            | Ok diff_document -> (
                match semantic_files_for_diff ~repo_root diff_document with
                | Error message -> Error message
                | Ok semantic_files ->
                    let semantic_document =
                      match semantic_files with
                      | [] -> None
                      | files ->
                          Some
                            {
                              Semantic_types.version = 1;
                              repo_root;
                              files;
                            }
                    in
                    let document = scene_for_diff ?semantic_document diff_document in
                let target_short_hash, target_date, target_timestamp, target_message =
                  commit_metadata ~repo_root target
                in
                Ok
                  {
                    index;
                    base;
                    target;
                    label = short_commit base ^ " -> " ^ short_commit target;
                    target_date;
                    target_timestamp;
                    target_short_hash;
                    target_message;
                    document;
                  })
          in
          let rec build_steps index acc = function
            | [] -> Ok (List.rev acc)
            | pair :: rest -> (
                match build_step index pair with
                | Error message -> Error message
                | Ok step -> build_steps (index + 1) (step :: acc) rest)
          in
          match build_steps 0 [] (pairs commits) with
          | Error message -> Error message
          | Ok steps -> Ok { version = 1; repo_root; base; target; steps })
