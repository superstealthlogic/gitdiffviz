open Diff_types
open Semantic_types

module TS = Tree_sitter_bindings.Tree_sitter_output_t

let language = "swift"
let extensions = [ ".swift" ]

external create_parser :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_swift"

type parent_symbol = {
  id : string;
  language_kind : string;
}

let parse source =
  let parser = create_parser () in
  let parsed =
    Tree_sitter_run.Tree_sitter_parsing.parse_source_string parser source
  in
  Tree_sitter_run.Tree_sitter_parsing.root parsed

let lines source = Array.of_list (String.split_on_char '\n' source)

let line_at lines row =
  if row >= 0 && row < Array.length lines then lines.(row) else ""

let substring_safe text start_col end_col =
  let len = String.length text in
  let start_col = max 0 (min start_col len) in
  let end_col = max start_col (min end_col len) in
  String.sub text start_col (end_col - start_col)

let text_of_node lines (node : TS.node) =
  if node.start_pos.row = node.end_pos.row then
    substring_safe (line_at lines node.start_pos.row) node.start_pos.column
      node.end_pos.column
  else
    let first_line = line_at lines node.start_pos.row in
    substring_safe first_line node.start_pos.column (String.length first_line)

let children (node : TS.node) = Option.value node.children ~default:[]

let node_span (node : TS.node) : source_span =
  Symbol_normalization.source_span ~start_row:node.start_pos.row
    ~end_row:node.end_pos.row

let trim = String.trim

let rec find_first_named names (node : TS.node) =
  if List.mem node.type_ names then Some node
  else children node |> List.find_map (find_first_named names)

let name_from_node lines node =
  find_first_named [ "type_identifier"; "simple_identifier"; "identifier"; "pattern" ] node
  |> Option.map (fun name_node ->
         text_of_node lines name_node
         |> trim
         |> fun value ->
         match String.split_on_char ':' value with
         | first :: _ -> trim first
         | [] -> value)

let declaration_header_window lines (node : TS.node) =
  let end_row = min node.end_pos.row (node.start_pos.row + 8) in
  let rec loop acc row =
    if row > end_row then List.rev acc
    else
      let line =
        if row = node.start_pos.row then
          substring_safe (line_at lines row) node.start_pos.column
            (String.length (line_at lines row))
        else line_at lines row
      in
      loop (trim line :: acc) (row + 1)
  in
  loop [] node.start_pos.row |> String.concat " "

let identifier_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' -> true
  | _ -> false

let header_tokens header =
  let len = String.length header in
  let rec loop acc index =
    if index >= len then List.rev acc
    else if identifier_char header.[index] then
      let start = index in
      let rec take index =
        if index < len && identifier_char header.[index] then take (index + 1)
        else index
      in
      let end_index = take index in
      let token = String.sub header start (end_index - start) in
      loop (token :: acc) end_index
    else loop acc (index + 1)
  in
  loop [] 0

let name_after_keyword keywords header =
  let tokens = header_tokens header in
  let rec loop = function
    | keyword :: name :: _ when List.mem keyword keywords -> Some name
    | _ :: rest -> loop rest
    | [] -> None
  in
  loop tokens

let name_from_header lines node language_kind =
  let header = declaration_header_window lines node in
  match language_kind with
  | "class" -> name_after_keyword [ "class" ] header
  | "struct" -> name_after_keyword [ "struct" ] header
  | "enum" -> name_after_keyword [ "enum" ] header
  | "actor" -> name_after_keyword [ "actor" ] header
  | "protocol" -> name_after_keyword [ "protocol" ] header
  | "extension" -> name_after_keyword [ "extension" ] header
  | "function" | "method" -> name_after_keyword [ "func" ] header
  | "property" -> name_after_keyword [ "let"; "var" ] header
  | "type_alias" -> name_after_keyword [ "typealias" ] header
  | _ -> None

let class_like_kind lines node =
  let tokens = declaration_header_window lines node |> header_tokens in
  if List.mem "struct" tokens then "struct"
  else if List.mem "enum" tokens then "enum"
  else if List.mem "actor" tokens then "actor"
  else if List.mem "extension" tokens then "extension"
  else "class"

let parent_is_type = function
  | parent :: _ ->
      List.mem parent.language_kind
        [ "class"; "struct"; "enum"; "actor"; "extension"; "protocol" ]
  | [] -> false

let has_type_parameters node =
  children node |> List.exists (fun child -> String.equal child.TS.type_ "type_parameters")

let kind_for lines node parents =
  match node.TS.type_ with
  | "class_declaration" ->
      let language_kind = class_like_kind lines node in
      (Type_container, language_kind)
  | "protocol_declaration" -> (Type_container, "protocol")
  | "function_declaration" when parent_is_type parents -> (Function, "method")
  | "function_declaration" -> (Function, "function")
  | "init_declaration" -> (Function, "initializer")
  | "deinit_declaration" -> (Function, "deinitializer")
  | "property_declaration" -> (Symbol, "property")
  | "typealias_declaration" -> (Symbol, "type_alias")
  | _ -> (Symbol, node.type_)

let default_name lines node language_kind =
  match language_kind with
  | "initializer" -> Some "init"
  | "deinitializer" -> Some "deinit"
  | _ -> (
      match name_from_header lines node language_kind with
      | Some name -> Some name
      | None -> name_from_node lines node)

let make_symbol ~path ~lines ~parents node =
  let kind, language_kind = kind_for lines node parents in
  match default_name lines node language_kind with
  | None -> None
  | Some name ->
      let span = node_span node in
      let parent_symbol_id =
        match parents with [] -> None | parent :: _ -> Some parent.id
      in
      let semantic =
        if has_type_parameters node then Symbol_normalization.generic_semantic ()
        else empty_semantic_properties
      in
      Some
        (Symbol_normalization.make_symbol ~path ~kind ~language_kind ~name ~span
           ?parent_symbol_id ~semantic ())

let is_container_kind = function
  | Type_container -> true
  | Function | Symbol -> false

let is_item_node (node : TS.node) =
  match node.type_ with
  | "class_declaration" | "protocol_declaration" | "function_declaration"
  | "init_declaration" | "deinit_declaration" | "property_declaration"
  | "typealias_declaration" ->
      true
  | _ -> false

let rec walk_node ~path ~lines ~parents node =
  if is_item_node node then
    let symbol = make_symbol ~path ~lines ~parents node in
    let parents =
      match symbol with
      | Some symbol when is_container_kind symbol.kind ->
          {
            id = symbol.id;
            language_kind = Option.value symbol.language_kind ~default:"";
          }
          :: parents
      | _ -> parents
    in
    let nested = walk_children ~path ~lines ~parents (children node) in
    (match symbol with None -> nested | Some symbol -> symbol :: nested)
  else walk_children ~path ~lines ~parents (children node)

and walk_children ~path ~lines ~parents nodes =
  nodes |> List.concat_map (walk_node ~path ~lines ~parents)

let extract ~repo_root:_ ~path ~source =
  let lines = lines source in
  let root = parse source in
  Ok (walk_node ~path ~lines ~parents:[] root |> Symbol_normalization.sort_symbols)
