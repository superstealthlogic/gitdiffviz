open Semantic_types

let read_file path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        let length = in_channel_length channel in
        Ok (really_input_string channel length))
  with Sys_error message -> Result.error message

let normalize_relative path =
  path
  |> String.split_on_char Filename.dir_sep.[0]
  |> List.filter (fun part -> part <> "" && part <> ".")
  |> String.concat "/"

let absolute_path repo_root path =
  if Filename.is_relative path then Filename.concat repo_root path else path

let relative_path repo_root path =
  if Filename.is_relative path then normalize_relative path
  else
    let repo_prefix =
      if String.ends_with ~suffix:Filename.dir_sep repo_root then repo_root
      else repo_root ^ Filename.dir_sep
    in
    if String.starts_with ~prefix:repo_prefix path then
      String.sub path (String.length repo_prefix)
        (String.length path - String.length repo_prefix)
      |> normalize_relative
    else normalize_relative path

let rec map_result f = function
  | [] -> Ok []
  | value :: rest -> (
      match (f value, map_result f rest) with
      | Ok value, Ok rest -> Ok (value :: rest)
      | Error message, _ | _, Error message -> Result.error message)

let extract_one repo_root path =
  let absolute = absolute_path repo_root path in
  let relative = relative_path repo_root path in
  match read_file absolute with
  | Error message -> Result.error message
  | Ok source -> Parser_registry.extract_file ~repo_root ~path:relative ~source

let extract ~repo_root ~files =
  let absolute_repo_root =
    if Filename.is_relative repo_root then Filename.concat (Sys.getcwd ()) repo_root
    else repo_root
  in
  match map_result (extract_one absolute_repo_root) files with
  | Error message -> Result.error message
  | Ok entries ->
      Ok
        {
          version = 1;
          repo_root = absolute_repo_root;
          files = List.filter_map Fun.id entries;
        }
