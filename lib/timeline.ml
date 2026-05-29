open Scene_types

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
  match run_git_capture repo_root [ "show"; "-s"; "--format=%h%x09%cs"; commit ] with
  | Error _ -> (None, None)
  | Ok output -> (
      match String.trim output |> String.split_on_char '\t' with
      | short_hash :: date :: _ -> (Some short_hash, Some date)
      | _ -> (None, None))

let pairs commits =
  let rec loop acc = function
    | left :: right :: rest -> loop ((left, right) :: acc) (right :: rest)
    | _ -> List.rev acc
  in
  loop [] commits

let scene_for_diff diff_document =
  let hierarchy_document = Hierarchy.build diff_document in
  Semantic_join.from_repository_hierarchy hierarchy_document |> Scene.build

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
            | Ok diff_document ->
                let document = scene_for_diff diff_document in
                let target_short_hash, target_date =
                  commit_metadata ~repo_root target
                in
                Ok
                  {
                    index;
                    base;
                    target;
                    label = short_commit base ^ " -> " ^ short_commit target;
                    target_date;
                    target_short_hash;
                    document;
                  }
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
