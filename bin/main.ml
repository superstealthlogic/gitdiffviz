open Cmdliner
open Git_visualization_diff

let result_to_exit = function
  | Ok () -> `Ok ()
  | Error message -> `Error (false, message)

let build_hierarchy diff_path out_path =
  let result =
    match Json_codec.read_json_file diff_path with
    | Error message -> Error message
    | Ok json -> (
        match Json_codec.git_diff_document_of_yojson json with
        | Error message -> Error message
        | Ok diff_document ->
            let hierarchy = Hierarchy.build diff_document in
            let json =
              Json_codec.repository_hierarchy_document_to_yojson hierarchy
            in
            (match out_path with
            | None ->
                Yojson.Safe.pretty_to_channel stdout json;
                output_char stdout '\n';
                Ok ()
            | Some path -> Json_codec.write_json_file path json))
  in
  result_to_exit result

let read_diff path =
  match Json_codec.read_json_file path with
  | Error message -> Error message
  | Ok json -> Json_codec.git_diff_document_of_yojson json

let read_semantic path =
  match Json_codec.read_json_file path with
  | Error message -> Error message
  | Ok json -> Json_codec.semantic_input_document_of_yojson json

let write_or_stdout out_path json =
  match out_path with
  | None ->
      Yojson.Safe.pretty_to_channel stdout json;
      output_char stdout '\n';
      Ok ()
  | Some path -> Json_codec.write_json_file path json

let build_semantic_hierarchy diff_path semantic_path out_path =
  let result =
    match (read_diff diff_path, read_semantic semantic_path) with
    | Error message, _ | _, Error message -> Error message
    | Ok diff_document, Ok semantic_document ->
        let hierarchy_document = Hierarchy.build diff_document in
        let semantic_hierarchy =
          Semantic_join.build ~diff_document ~hierarchy_document ~semantic_document
        in
        semantic_hierarchy
        |> Json_codec.semantic_hierarchy_document_to_yojson
        |> write_or_stdout out_path
  in
  result_to_exit result

let build_scene diff_path semantic_path out_path =
  let result =
    match read_diff diff_path with
    | Error message -> Error message
    | Ok diff_document -> (
        let hierarchy_document = Hierarchy.build diff_document in
        let semantic_hierarchy =
          match semantic_path with
          | None -> Semantic_join.from_repository_hierarchy hierarchy_document
          | Some path -> (
              match read_semantic path with
              | Error message -> raise (Failure message)
              | Ok semantic_document ->
                  Semantic_join.build ~diff_document ~hierarchy_document
                    ~semantic_document)
        in
        semantic_hierarchy |> Scene.build
        |> Json_codec.visualization_document_to_yojson
        |> write_or_stdout out_path)
  in
  match result with
  | Ok () -> `Ok ()
  | Error message -> `Error (false, message)
  | exception Failure message -> `Error (false, message)

let extract_semantics repo_root files out_path =
  let result =
    match Semantic_extract.extract ~repo_root ~files with
    | Error message -> Error message
    | Ok semantic_document ->
        semantic_document |> Json_codec.semantic_input_document_to_yojson
        |> write_or_stdout out_path
  in
  result_to_exit result

let extract_diff repo_root base target path_filter out_path =
  let result =
    match Git_diff.extract ~repo_root ~base ~target ~path_filter with
    | Error message -> Error message
    | Ok diff_document ->
        diff_document |> Json_codec.git_diff_document_to_yojson
        |> write_or_stdout out_path
  in
  result_to_exit result

let recognized_semantic_path path =
  match Language.detect_by_path path with
  | "c" | "cpp" | "rust" | "swift" -> true
  | _ -> false

let semantic_candidate_files diff_document =
  diff_document.Diff_types.files
  |> List.filter_map (fun (file : Diff_types.diff_file_entry) ->
         match file.status with
         | Deleted -> None
         | _ when recognized_semantic_path file.path -> Some file.path
         | _ -> None)

let scene_for_diff repo_root diff_document =
  let semantic_files = semantic_candidate_files diff_document in
  match semantic_files with
  | [] ->
      let hierarchy_document = Hierarchy.build diff_document in
      Semantic_join.from_repository_hierarchy hierarchy_document |> Scene.build
      |> fun document -> Ok document
  | files -> (
      match Semantic_extract.extract ~repo_root ~files with
      | Error message -> Error message
      | Ok semantic_document ->
          let hierarchy_document = Hierarchy.build diff_document in
          Semantic_join.build ~diff_document ~hierarchy_document ~semantic_document
          |> Scene.build |> fun document -> Ok document)

let render_repo repo_root base target path_filter timeline out_path =
  let result =
    if timeline then
      match Timeline.build ~repo_root ~base ~target ~path_filter with
      | Error message -> Error message
      | Ok timeline_document ->
          timeline_document |> Json_codec.timeline_document_to_yojson
          |> write_or_stdout out_path
    else
      match Git_diff.extract ~repo_root ~base ~target ~path_filter with
      | Error message -> Error message
      | Ok diff_document ->
          let repo_root = diff_document.repo_root in
          match scene_for_diff repo_root diff_document with
          | Error message -> Error message
          | Ok scene_document ->
              scene_document |> Json_codec.visualization_document_to_yojson
              |> write_or_stdout out_path
  in
  result_to_exit result

let build_timeline repo_root base target path_filter out_path =
  let result =
    match Timeline.build ~repo_root ~base ~target ~path_filter with
    | Error message -> Error message
    | Ok timeline ->
        timeline |> Json_codec.timeline_document_to_yojson |> write_or_stdout out_path
  in
  result_to_exit result

let diff_arg =
  let doc = "Read a saved git diff JSON document from $(docv)." in
  Arg.(required & opt (some file) None & info [ "diff" ] ~docv:"PATH" ~doc)

let out_arg =
  let doc = "Write output JSON to $(docv). If omitted, write to stdout." in
  Arg.(value & opt (some string) None & info [ "out" ] ~docv:"PATH" ~doc)

let semantic_arg =
  let doc = "Read a semantic input JSON document from $(docv)." in
  Arg.(required & opt (some file) None & info [ "semantic" ] ~docv:"PATH" ~doc)

let optional_semantic_arg =
  let doc = "Optionally read a semantic input JSON document from $(docv)." in
  Arg.(value & opt (some file) None & info [ "semantic" ] ~docv:"PATH" ~doc)

let repo_arg =
  let doc = "Use $(docv) as the git repository path." in
  Arg.(value & opt string "." & info [ "repo" ] ~docv:"PATH" ~doc)

let base_arg =
  let doc = "Use $(docv) as the base revision." in
  Arg.(required & opt (some string) None & info [ "base" ] ~docv:"REV" ~doc)

let target_arg =
  let doc = "Use $(docv) as the target revision." in
  Arg.(required & opt (some string) None & info [ "target" ] ~docv:"REV" ~doc)

let path_filter_arg =
  let doc = "Restrict git diff extraction to $(docv)." in
  Arg.(value & opt (some string) None & info [ "path" ] ~docv:"PATH" ~doc)

let files_arg =
  let doc = "Analyze repo-relative source files." in
  Arg.(non_empty & pos_all string [] & info [] ~docv:"FILES" ~doc)

let build_hierarchy_cmd =
  let doc = "Build a repository hierarchy document from a saved diff JSON." in
  let info = Cmd.info "build-hierarchy" ~doc in
  Cmd.v info Term.(ret (const build_hierarchy $ diff_arg $ out_arg))

let build_semantic_hierarchy_cmd =
  let doc = "Build a semantic hierarchy document from diff and semantic JSON." in
  let info = Cmd.info "build-semantic-hierarchy" ~doc in
  Cmd.v info
    Term.(ret (const build_semantic_hierarchy $ diff_arg $ semantic_arg $ out_arg))

let extract_diff_cmd =
  let doc = "Extract a structured git diff document from two revisions." in
  let info = Cmd.info "extract-diff" ~doc in
  Cmd.v info
    Term.(
      ret
        (const extract_diff $ repo_arg $ base_arg $ target_arg $ path_filter_arg
       $ out_arg))

let extract_semantics_cmd =
  let doc =
    "Extract semantic input JSON for recognized source files. Symbol extractors are placeholders for now."
  in
  let info = Cmd.info "extract-semantics" ~doc in
  Cmd.v info Term.(ret (const extract_semantics $ repo_arg $ files_arg $ out_arg))

let build_scene_cmd =
  let doc = "Build a renderer-ready scene document from saved inputs." in
  let info = Cmd.info "build-scene" ~doc in
  Cmd.v info
    Term.(ret (const build_scene $ diff_arg $ optional_semantic_arg $ out_arg))

let build_timeline_cmd =
  let doc =
    "Build renderer-ready timeline scenes for adjacent commits between two revisions."
  in
  let info = Cmd.info "build-timeline" ~doc in
  Cmd.v info
    Term.(
      ret
        (const build_timeline $ repo_arg $ base_arg $ target_arg $ path_filter_arg
       $ out_arg))

let timeline_flag =
  let doc = "Build a timeline document instead of a single scene." in
  Arg.(value & flag & info [ "timeline" ] ~doc)

let render_repo_cmd =
  let doc = "Run the repository diff pipeline and write renderer-ready JSON." in
  let info = Cmd.info "render-repo" ~doc in
  Cmd.v info
    Term.(
      ret
        (const render_repo $ repo_arg $ base_arg $ target_arg $ path_filter_arg
       $ timeline_flag $ out_arg))

let default_cmd =
  let doc = "Typed OCaml backend for git diff visualization documents." in
  let info = Cmd.info "git-visualization-diff" ~version:"0.1.0" ~doc in
  Cmd.group info
    [
      build_hierarchy_cmd;
      build_semantic_hierarchy_cmd;
      build_scene_cmd;
      build_timeline_cmd;
      extract_diff_cmd;
      extract_semantics_cmd;
      render_repo_cmd;
    ]

let () = exit (Cmd.eval default_cmd)
