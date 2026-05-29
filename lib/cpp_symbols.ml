open Diff_types
open Semantic_types

module TS = Tree_sitter_bindings.Tree_sitter_output_t

let language = "cpp"
let extensions = [ ".c"; ".h"; ".cc"; ".cpp"; ".cxx"; ".hh"; ".hpp" ]

external create_parser :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_cpp"

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

let rec find_first_named names (node : TS.node) =
  if List.mem node.type_ names then Some node
  else children node |> List.find_map (find_first_named names)

let rec collect_descendants kind (node : TS.node) =
  let here = if String.equal node.type_ kind then [ node ] else [] in
  here @ (children node |> List.concat_map (collect_descendants kind))

let node_span (node : TS.node) : source_span =
  Symbol_normalization.source_span ~start_row:node.start_pos.row
    ~end_row:node.end_pos.row

let name_from_named_node lines node =
  find_first_named
    [
      "type_identifier";
      "identifier";
      "namespace_identifier";
      "field_identifier";
      "qualified_identifier";
      "operator_name";
    ]
    node
  |> Option.map (text_of_node lines)

let function_name lines node =
  let declarators = collect_descendants "function_declarator" node in
  match declarators with
  | [] -> name_from_named_node lines node
  | declarator :: _ -> name_from_named_node lines declarator

let has_descendant kind node = collect_descendants kind node <> []

let parent_is_type_container = function
  | parent :: _ ->
      List.mem parent.language_kind [ "class"; "struct"; "union" ]
  | [] -> false

let kind_for node ~has_type_parent =
  match node.TS.type_ with
  | "class_specifier" -> (Type_container, "class")
  | "struct_specifier" -> (Type_container, "struct")
  | "union_specifier" -> (Type_container, "union")
  | "enum_specifier" -> (Type_container, "enum")
  | "namespace_definition" -> (Type_container, "namespace")
  | "function_definition" | "declaration"
    when has_type_parent && has_descendant "function_declarator" node ->
      (Function, "method")
  | "function_definition" | "declaration" when has_descendant "function_declarator" node ->
      (Function, "function")
  | "declaration" when has_type_parent -> (Symbol, "field")
  | _ -> (Symbol, node.type_)

let rec template_subject_node node =
  let is_subject node =
    match node.TS.type_ with
    | "class_specifier" | "struct_specifier" | "union_specifier" | "enum_specifier"
    | "function_definition" | "declaration" ->
        true
    | _ -> false
  in
  if is_subject node then Some node
  else children node |> List.find_map template_subject_node

let is_container_kind = function
  | Type_container -> true
  | Function | Symbol -> false

let make_symbol ~path ~lines ~parents node =
  let has_type_parent = parent_is_type_container parents in
  let subject =
    if String.equal node.TS.type_ "template_declaration" then
      template_subject_node node
    else Some node
  in
  match subject with
  | None -> None
  | Some subject ->
      let kind, language_kind = kind_for subject ~has_type_parent in
      let name =
        match subject.type_ with
        | "function_definition" | "declaration" -> function_name lines subject
        | _ -> name_from_named_node lines subject
      in
      match name with
      | None -> None
      | Some name ->
          let span = node_span node in
          let parent_symbol_id =
            match parents with [] -> None | parent :: _ -> Some parent.id
          in
          let semantic =
            if String.equal node.TS.type_ "template_declaration" then
              Symbol_normalization.generic_semantic
                ~patterns:[ "template"; "generic" ] ()
            else empty_semantic_properties
          in
          Some
            (Symbol_normalization.make_symbol ~path ~kind ~language_kind ~name
               ~span ?parent_symbol_id ~semantic ())

let is_item_node (node : TS.node) =
  match node.type_ with
  | "class_specifier" | "struct_specifier" | "union_specifier" | "enum_specifier"
  | "namespace_definition" | "function_definition" | "template_declaration" ->
      true
  | _ -> false

let rec walk_node ~path ~lines ~parents node =
  if String.equal node.TS.type_ "template_declaration" then
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
    let nested =
      match template_subject_node node with
      | Some subject when
          (match symbol with
          | Some symbol -> is_container_kind symbol.kind
          | None -> false) ->
          walk_children ~path ~lines ~parents (children subject)
      | _ -> []
    in
    (match symbol with None -> nested | Some symbol -> symbol :: nested)
  else if is_item_node node then
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
