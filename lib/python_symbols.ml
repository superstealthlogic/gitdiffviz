open Semantic_types

module TS = Ts_node.TS

let language = "python"
let extensions = [ ".py"; ".pyi" ]

external create_parser :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_python"

type parent_symbol = {
  id : string;
  language_kind : string;
}

(* Assignments are only interesting as symbols outside function bodies:
   module-level constants and class attributes. *)
type scope =
  | Module_scope
  | Class_scope
  | Function_scope

let parse source =
  let parser = create_parser () in
  let parsed =
    Tree_sitter_run.Tree_sitter_parsing.parse_source_string parser source
  in
  Tree_sitter_run.Tree_sitter_parsing.root parsed

let starts_with ~prefix value = String.starts_with ~prefix value

(* "@pytest.mark.parametrize(...)" -> "pytest.mark.parametrize" *)
let decorator_name lines (node : TS.node) =
  let text = Ts_node.trimmed_text lines node in
  let text =
    if starts_with ~prefix:"@" text then
      String.sub text 1 (String.length text - 1)
    else text
  in
  let text = match String.index_opt text '(' with
    | None -> text
    | Some index -> String.sub text 0 index
  in
  String.trim text

let decorator_leaf name =
  match String.rindex_opt name '.' with
  | None -> name
  | Some index -> String.sub name (index + 1) (String.length name - index - 1)

let is_pytest_decorator name =
  String.equal name "pytest" || starts_with ~prefix:"pytest." name

let is_test_name name = starts_with ~prefix:"test_" name || String.equal name "test"
let is_test_class_name name = starts_with ~prefix:"Test" name

let is_upper_snake name =
  String.length name > 0
  && String.for_all
       (function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
       name

(* Decorators that change what a function *is*, rather than just tagging it. *)
let kind_from_decorators decorators =
  let leaves = List.map decorator_leaf decorators in
  if List.mem "property" leaves || List.mem "cached_property" leaves then
    Some "property"
  else if List.mem "setter" leaves || List.mem "deleter" leaves then
    (* `@name.setter` reuses the property name; keep it distinguishable. *)
    Some "property"
  else if List.mem "staticmethod" leaves then Some "static_method"
  else if List.mem "classmethod" leaves then Some "class_method"
  else None

let semantic_from_decorators decorators =
  let leaves = List.map decorator_leaf decorators in
  let has leaf = List.mem leaf leaves in
  let is_test = List.exists is_pytest_decorator decorators in
  let patterns =
    List.filter_map
      (fun (condition, tag) -> if condition then Some tag else None)
      [
        (is_test, "test");
        (has "abstractmethod" || has "abstractproperty", "abstract");
        (has "dataclass", "dataclass");
        (has "contextmanager" || has "asynccontextmanager", "context_manager");
        (has "override", "override");
      ]
  in
  {
    empty_semantic_properties with
    patterns;
    paradigms = (if is_test then [ "test" ] else []);
  }

(* PEP 695 declares type parameters as `type_parameter` children. *)
let has_type_parameters node = Ts_node.has_child_type [ "type_parameter" ] node
let is_async node = Ts_node.has_child_type [ "async" ] node

let parent_is_class = function
  | parent :: _ -> List.mem parent.language_kind [ "class"; "test_class" ]
  | [] -> false

let superclass_names lines node =
  match Ts_node.first_child_of_type [ "argument_list" ] node with
  | None -> []
  | Some argument_list ->
      Ts_node.children argument_list
      |> List.filter_map (fun (child : TS.node) ->
             match child.type_ with
             | "identifier" | "attribute" ->
                 Some (Ts_node.trimmed_text lines child)
             | _ -> None)

let class_semantic lines node =
  let bases = superclass_names lines node |> List.map decorator_leaf in
  let patterns =
    List.filter_map
      (fun (base, tag) -> if List.mem base bases then Some tag else None)
      [
        ("ABC", "abstract");
        ("ABCMeta", "abstract");
        ("Protocol", "protocol");
        ("Enum", "enum");
        ("IntEnum", "enum");
        ("StrEnum", "enum");
        ("TypedDict", "typed_dict");
        ("NamedTuple", "named_tuple");
        ("BaseModel", "model");
        ("Exception", "exception");
      ]
  in
  { empty_semantic_properties with patterns }

let function_kind ~name ~decorators ~parents =
  match kind_from_decorators decorators with
  | Some language_kind -> language_kind
  | None ->
      let in_class = parent_is_class parents in
      if is_test_name name && not in_class then "test_function"
      else if is_test_name name then "test_method"
      else if in_class then "method"
      else "function"

(* The name node for `class Spam(...)` / `def spam(...)` is the identifier that
   follows the keyword; the bindings expose keyword tokens as children. *)
let declaration_name lines ~keywords node =
  Ts_node.child_after ~keywords ~types:[ "identifier" ] node
  |> Option.map (Ts_node.trimmed_text lines)

let assignment_target lines (node : TS.node) =
  match Ts_node.children node with
  | target :: _ when String.equal target.TS.type_ "identifier" ->
      Some (Ts_node.trimmed_text lines target)
  | _ -> None

(* `type` is a soft keyword, so `type(item).attr = value` also parses as a
   `type_alias_statement` whose left-hand side is `(item).attr`. Only accept a
   left-hand side that could be a declared name. *)
let is_name_like value =
  String.length value > 0
  && (match value.[0] with '0' .. '9' -> false | _ -> true)
  && String.for_all
       (function
         | '(' | ')' | '[' | ']' | '{' | '}' | '.' | ',' | ':' | ';' | '=' | '*'
         | '"' | '\'' | ' ' | '\t' | '\n' ->
             false
         | _ -> true)
       value

(* `type Alias[T] = ...` (PEP 695). Children are the `type` keyword token, the
   left-hand `type` node, `=`, then the right-hand `type` node. *)
let type_alias_name lines (node : TS.node) =
  match Ts_node.children node with
  | _keyword :: left :: _ when String.equal left.TS.type_ "type" ->
      let text = Ts_node.trimmed_text lines left in
      let name =
        match String.index_opt text '[' with
        | None -> text
        | Some index -> String.sub text 0 index |> String.trim
      in
      if is_name_like name then Some name else None
  | _ -> None

let make_symbol ~path ~span ~kind ~language_kind ~name ~parents ~semantic =
  let parent_symbol_id =
    match parents with [] -> None | parent :: _ -> Some parent.id
  in
  Symbol_normalization.make_symbol ~path ~kind ~language_kind ~name ~span
    ?parent_symbol_id ~semantic ()

let class_symbol ~path ~lines ~span ~decorators ~parents node =
  match declaration_name lines ~keywords:[ "class" ] node with
  | None -> None
  | Some name ->
      let decorator_semantic = semantic_from_decorators decorators in
      let is_test =
        is_test_class_name name
        || List.mem "test" decorator_semantic.patterns
      in
      let language_kind = if is_test then "test_class" else "class" in
      let semantic =
        merge_semantic_properties decorator_semantic (class_semantic lines node)
      in
      let semantic =
        if is_test then
          merge_semantic_properties semantic
            (Symbol_normalization.semantic_tags ~patterns:[ "test" ]
               ~paradigms:[ "test" ] ())
        else semantic
      in
      let semantic =
        if has_type_parameters node then
          merge_semantic_properties semantic
            (Symbol_normalization.generic_semantic ())
        else semantic
      in
      Some
        (make_symbol ~path ~span ~kind:Type_container ~language_kind ~name
           ~parents ~semantic)

let function_symbol ~path ~lines ~span ~decorators ~parents node =
  match declaration_name lines ~keywords:[ "def" ] node with
  | None -> None
  | Some name ->
      let language_kind = function_kind ~name ~decorators ~parents in
      let semantic = semantic_from_decorators decorators in
      let semantic =
        if is_test_name name || String.equal language_kind "test_method" then
          merge_semantic_properties semantic
            (Symbol_normalization.semantic_tags ~patterns:[ "test" ]
               ~paradigms:[ "test" ] ())
        else semantic
      in
      let semantic =
        if is_async node then
          merge_semantic_properties semantic
            (Symbol_normalization.semantic_tags ~patterns:[ "async" ]
               ~paradigms:[ "async" ] ())
        else semantic
      in
      let semantic =
        if has_type_parameters node then
          merge_semantic_properties semantic
            (Symbol_normalization.generic_semantic ())
        else semantic
      in
      Some
        (make_symbol ~path ~span ~kind:Function ~language_kind ~name
           ~parents ~semantic)

let assignment_symbol ~path ~lines ~scope ~parents node =
  match assignment_target lines node with
  | None -> None
  | Some name -> (
      let span = Ts_node.node_span node in
      match scope with
      | Class_scope ->
          Some
            (make_symbol ~path ~span ~kind:Symbol ~language_kind:"attribute"
               ~name ~parents ~semantic:empty_semantic_properties)
      | Module_scope when is_upper_snake name ->
          Some
            (make_symbol ~path ~span ~kind:Symbol ~language_kind:"constant"
               ~name ~parents ~semantic:empty_semantic_properties)
      | Module_scope | Function_scope -> None)

let type_alias_symbol ~path ~lines ~parents node =
  match type_alias_name lines node with
  | None -> None
  | Some name ->
      Some
        (make_symbol ~path ~span:(Ts_node.node_span node) ~kind:Symbol
           ~language_kind:"type_alias" ~name ~parents
           ~semantic:empty_semantic_properties)

let parent_of_symbol (symbol : semantic_symbol) =
  {
    id = symbol.id;
    language_kind = Option.value symbol.language_kind ~default:"";
  }

let body_scope (symbol : semantic_symbol) =
  match symbol.kind with
  | Type_container -> Class_scope
  | Function -> Function_scope
  | Symbol -> Function_scope

(* [span] lets a decorated definition claim the decorator lines, so a diff that
   only touches `@app.route(...)` still maps to the handler it decorates. *)
let rec walk_node ~path ~lines ~scope ~parents ?span ?(decorators = []) node =
  let span = Option.value span ~default:(Ts_node.node_span node) in
  match node.TS.type_ with
  | "decorated_definition" ->
      let decorators =
        Ts_node.children node
        |> List.filter (fun (child : TS.node) ->
               String.equal child.type_ "decorator")
        |> List.map (decorator_name lines)
      in
      let definition =
        Ts_node.first_child_of_type
          [ "class_definition"; "function_definition" ]
          node
      in
      (match definition with
      | None -> []
      | Some definition ->
          walk_node ~path ~lines ~scope ~parents ~span ~decorators definition)
  | "class_definition" | "function_definition" ->
      let symbol =
        if String.equal node.type_ "class_definition" then
          class_symbol ~path ~lines ~span ~decorators ~parents node
        else function_symbol ~path ~lines ~span ~decorators ~parents node
      in
      let child_scope, child_parents =
        match symbol with
        | Some symbol ->
            (body_scope symbol, parent_of_symbol symbol :: parents)
        | None -> (Function_scope, parents)
      in
      let nested =
        walk_children ~path ~lines ~scope:child_scope ~parents:child_parents
          (Ts_node.children node)
      in
      (match symbol with None -> nested | Some symbol -> symbol :: nested)
  | "assignment" -> (
      match assignment_symbol ~path ~lines ~scope ~parents node with
      | None -> []
      | Some symbol -> [ symbol ])
  | "type_alias_statement" -> (
      match type_alias_symbol ~path ~lines ~parents node with
      | None -> []
      | Some symbol -> [ symbol ])
  | _ -> walk_children ~path ~lines ~scope ~parents (Ts_node.children node)

and walk_children ~path ~lines ~scope ~parents nodes =
  nodes |> List.concat_map (walk_node ~path ~lines ~scope ~parents)

let extract ~repo_root:_ ~path ~source =
  let lines = Ts_node.lines source in
  let root = parse source in
  Ok
    (walk_node ~path ~lines ~scope:Module_scope ~parents:[] root
    |> Symbol_normalization.sort_symbols)
