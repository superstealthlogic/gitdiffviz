open Diff_types

module TS = Tree_sitter_bindings.Tree_sitter_output_t

let lines source = Array.of_list (String.split_on_char '\n' source)

let line_at lines row =
  if row >= 0 && row < Array.length lines then lines.(row) else ""

let substring_safe text start_col end_col =
  let len = String.length text in
  let start_col = max 0 (min start_col len) in
  let end_col = max start_col (min end_col len) in
  String.sub text start_col (end_col - start_col)

let text_of_node lines (node : TS.node) =
  let start_row = node.start_pos.row in
  let end_row = node.end_pos.row in
  if start_row = end_row then
    substring_safe (line_at lines start_row) node.start_pos.column
      node.end_pos.column
  else
    let rec loop acc row =
      if row > end_row then List.rev acc
      else
        let line = line_at lines row in
        let piece =
          if row = start_row then
            substring_safe line node.start_pos.column (String.length line)
          else if row = end_row then substring_safe line 0 node.end_pos.column
          else line
        in
        loop (piece :: acc) (row + 1)
    in
    loop [] start_row |> String.concat "\n"

(* The OCaml tree-sitter bindings expose every child, including anonymous
   keyword tokens, and expose no field names. Keyword-relative lookup is
   therefore how these adapters recover a declaration's name node. *)
let children (node : TS.node) = Option.value node.children ~default:[]

let child_types node = children node |> List.map (fun child -> child.TS.type_)

let has_child_type types node =
  children node |> List.exists (fun child -> List.mem child.TS.type_ types)

let first_child_of_type types node =
  children node |> List.find_opt (fun child -> List.mem child.TS.type_ types)

(* First child whose type is in [types] that appears after a child whose type is
   in [keywords]. For `def spam(...)` with keywords ["def"] and types
   ["identifier"], this is the `spam` node. *)
let child_after ~keywords ~types node =
  let rec loop seen_keyword = function
    | [] -> None
    | (child : TS.node) :: rest ->
        if seen_keyword && List.mem child.type_ types then Some child
        else loop (seen_keyword || List.mem child.type_ keywords) rest
  in
  loop false (children node)

let rec find_first_of_type types (node : TS.node) =
  if List.mem node.type_ types then Some node
  else children node |> List.find_map (find_first_of_type types)

let rec exists_descendant types (node : TS.node) =
  List.mem node.type_ types
  || children node |> List.exists (exists_descendant types)

let node_span (node : TS.node) : source_span =
  Symbol_normalization.source_span ~start_row:node.start_pos.row
    ~end_row:node.end_pos.row

let trimmed_text lines node = text_of_node lines node |> String.trim
