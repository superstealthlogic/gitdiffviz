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

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix

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

let declaration_header lines node =
  line_at lines node.TS.start_pos.row
  |> fun line -> substring_safe line node.start_pos.column (String.length line)
  |> trim

let class_like_kind lines node =
  let header = declaration_header lines node in
  if starts_with ~prefix:"struct " header then "struct"
  else if starts_with ~prefix:"enum " header then "enum"
  else if starts_with ~prefix:"actor " header then "actor"
  else if starts_with ~prefix:"extension " header then "extension"
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
  | "extension" -> name_from_node lines node
  | _ -> name_from_node lines node

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
