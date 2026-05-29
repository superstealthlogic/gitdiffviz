type revision_comparison = {
  base : string;
  target : string;
}

type source_span = {
  start_line : int;
  end_line : int;
}

type diff_metrics = {
  lines_added : int;
  lines_removed : int;
  changed_ratio : float;
}

type diff_file_status =
  | Unchanged
  | Modified
  | Added
  | Deleted
  | Renamed
  | Copied
  | Type_changed
  | Unmerged
  | Unknown

type diff_line_range = {
  start_line : int;
  line_count : int;
}

type diff_line_kind =
  | Context
  | Addition
  | Deletion

type diff_line = {
  kind : diff_line_kind;
  old_line : int option;
  new_line : int option;
  content : string;
}

type diff_hunk = {
  old_range : diff_line_range;
  new_range : diff_line_range;
  header : string;
  lines : diff_line list option;
}

type diff_line_change_kind =
  | Line_addition
  | Line_deletion

type diff_line_change = {
  kind : diff_line_change_kind;
  start_line : int;
  line_count : int;
}

type diff_file_entry = {
  path : string;
  old_path : string option;
  status : diff_file_status;
  additions : int;
  deletions : int;
  is_binary : bool;
  hunks : diff_hunk list;
}

type git_diff_summary = {
  changed_files : int;
  total_additions : int;
  total_deletions : int;
}

type git_diff_document = {
  version : int;
  repo_root : string;
  comparison : revision_comparison;
  path_filter : string option;
  files : diff_file_entry list;
  summary : git_diff_summary;
}

val diff_file_status_to_string : diff_file_status -> string
val diff_file_status_of_string : string -> diff_file_status
val diff_line_kind_to_string : diff_line_kind -> string
val diff_line_kind_of_string : string -> diff_line_kind option
val diff_line_change_kind_to_string : diff_line_change_kind -> string
val diff_line_change_kind_of_string : string -> diff_line_change_kind option
