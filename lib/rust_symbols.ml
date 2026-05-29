open Diff_types
open Semantic_types

module TS = Tree_sitter_bindings.Tree_sitter_output_t

let language = "rust"
let extensions = [ ".rs" ]

external create_parser :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_rust"

type pending_attribute =
  | Test
  | Other

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
    let first =
      substring_safe (line_at lines node.start_pos.row) node.start_pos.column
        (String.length (line_at lines node.start_pos.row))
    in
    let last = substring_safe (line_at lines node.end_pos.row) 0 node.end_pos.column in
    first ^ "\n" ^ last

let children (node : TS.node) = Option.value node.children ~default:[]

let rec find_first_identifier (node : TS.node) =
  match node.type_ with
  | "identifier" | "type_identifier" | "scoped_type_identifier" -> Some node
  | _ ->
      children node
      |> List.find_map find_first_identifier

let name_of_node lines node =
  find_first_identifier node |> Option.map (text_of_node lines)

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix

let trim = String.trim

let impl_name lines (node : TS.node) =
  let first_line = line_at lines node.start_pos.row in
  let header =
    substring_safe first_line node.start_pos.column (String.length first_line)
    |> trim
  in
  let header =
    match String.index_opt header '{' with
    | None -> header
    | Some index -> String.sub header 0 index |> trim
  in
  if starts_with ~prefix:"impl" header then header else "impl"

let node_span (node : TS.node) =
  Symbol_normalization.source_span ~start_row:node.start_pos.row
    ~end_row:node.end_pos.row

let contains_test_text text =
  String.equal text "#[test]"
  || starts_with ~prefix:"#[tokio::test" text
  || starts_with ~prefix:"#[async_std::test" text
  || String.equal text "#[cfg(test)]"

let attribute_kind lines node =
  let text = text_of_node lines node |> trim in
  if contains_test_text text then Test else Other

let has_test attrs = List.exists (( = ) Test) attrs

let semantic_for_attrs attrs =
  if has_test attrs then
    { empty_semantic_properties with patterns = [ "test" ]; paradigms = [ "test" ] }
  else empty_semantic_properties

let has_type_parameters node =
  children node |> List.exists (fun child -> String.equal child.TS.type_ "type_parameters")

let parent_is_impl_or_trait = function
  | parent :: _ -> List.mem parent.language_kind [ "impl"; "trait" ]
  | [] -> false

let kind_for node_type attrs parents =
  match node_type with
  | "struct_item" -> (Type_container, "struct")
  | "enum_item" -> (Type_container, "enum")
  | "trait_item" -> (Type_container, "trait")
  | "impl_item" -> (Type_container, "impl")
  | "mod_item" when has_test attrs -> (Type_container, "test_module")
  | "mod_item" -> (Type_container, "module")
  | "function_item" when has_test attrs -> (Function, "test_function")
  | "function_item" when parent_is_impl_or_trait parents -> (Function, "method")
  | "function_item" -> (Function, "function")
  | _ -> (Symbol, node_type)

let make_symbol ~path ~lines ~attrs ~parents node =
  let kind, language_kind = kind_for node.TS.type_ attrs parents in
  let name =
    match node.type_ with
    | "impl_item" -> Some (impl_name lines node)
    | _ -> name_of_node lines node
  in
  match name with
  | None -> None
  | Some name ->
      let span : source_span = node_span node in
      let parent_symbol_id =
        match parents with [] -> None | parent :: _ -> Some parent.id
      in
      let semantic =
        let attr_semantic = semantic_for_attrs attrs in
        if has_type_parameters node then
          merge_semantic_properties attr_semantic
            (Symbol_normalization.generic_semantic ())
        else attr_semantic
      in
      Some
        (Symbol_normalization.make_symbol ~path ~kind ~language_kind ~name ~span
           ?parent_symbol_id ~semantic ())

let parent_of_symbol (symbol : semantic_symbol) =
  match symbol.language_kind with
  | Some language_kind -> Some { id = symbol.id; language_kind }
  | None -> None

let is_container_symbol (symbol : semantic_symbol) =
  match symbol.kind with Type_container -> true | Function | Symbol -> false

let is_item_node (node : TS.node) =
  match node.type_ with
  | "struct_item" | "enum_item" | "trait_item" | "impl_item" | "mod_item"
  | "function_item" ->
      true
  | _ -> false

let is_attribute_node (node : TS.node) =
  String.equal node.type_ "attribute_item"
  || String.equal node.type_ "inner_attribute_item"

let rec walk_node ~path ~lines ~attrs ~parents node =
  if is_item_node node then
    let symbol = make_symbol ~path ~lines ~attrs ~parents node in
    let parents =
      match symbol with
      | Some symbol when is_container_symbol symbol -> (
          match parent_of_symbol symbol with
          | Some parent -> parent :: parents
          | None -> parents)
      | _ -> parents
    in
    let nested = walk_children ~path ~lines ~parents (children node) in
    (match symbol with None -> nested | Some symbol -> symbol :: nested)
  else walk_children ~path ~lines ~parents (children node)

and walk_children ~path ~lines ~parents nodes =
  let rec loop attrs acc = function
    | [] -> List.rev acc
    | node :: rest ->
        if is_attribute_node node then
          loop (attribute_kind lines node :: attrs) acc rest
        else
          let symbols =
            walk_node ~path ~lines ~attrs:(List.rev attrs) ~parents node
          in
          loop [] (List.rev_append symbols acc) rest
  in
  loop [] [] nodes

let extract ~repo_root:_ ~path ~source =
  let lines = lines source in
  let root = parse source in
  Ok (walk_node ~path ~lines ~attrs:[] ~parents:[] root |> Symbol_normalization.sort_symbols)
