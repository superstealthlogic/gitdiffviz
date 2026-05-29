open Scene_types

val build :
  repo_root:string ->
  base:string ->
  target:string ->
  path_filter:string option ->
  (timeline_document, string) result
