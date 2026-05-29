open Diff_types

type raw_git_diff_outputs = {
  name_status : string;
  numstat : string;
  unified_diff : string;
}

val parse_outputs :
  repo_root:string ->
  base:string ->
  target:string ->
  path_filter:string option ->
  raw_git_diff_outputs ->
  git_diff_document

val extract :
  repo_root:string ->
  base:string ->
  target:string ->
  path_filter:string option ->
  (git_diff_document, string) result
