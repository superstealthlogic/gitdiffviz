open Diff_types
open Semantic_types

let trim_name value = String.trim value

let source_span ~start_row ~end_row =
  {
    start_line = start_row + 1;
    end_line = max (start_row + 1) (end_row + 1);
  }

let symbol_id path language_kind name (span : source_span) =
  Printf.sprintf "%s::%s::%s@%d" path language_kind name span.start_line

let semantic_tags ?(patterns = []) ?(paradigms = []) () =
  { empty_semantic_properties with patterns; paradigms }

let generic_semantic ?(patterns = [ "generic" ]) () =
  semantic_tags ~patterns ~paradigms:[ "generic" ] ()

let make_symbol ~path ~kind ~language_kind ~name ~span ?parent_symbol_id
    ?(semantic = empty_semantic_properties) () =
  let name = trim_name name in
  {
    id = symbol_id path language_kind name span;
    kind;
    language_kind = Some language_kind;
    name;
    span;
    parent_symbol_id;
    semantic;
  }

let sort_symbols symbols =
  List.sort
    (fun (left : semantic_symbol) (right : semantic_symbol) ->
      match compare left.span.start_line right.span.start_line with
      | 0 -> (
          match compare right.span.end_line left.span.end_line with
          | 0 -> (
              match String.compare left.name right.name with
              | 0 -> String.compare left.id right.id
              | value -> value)
          | value -> value)
      | value -> value)
    symbols
