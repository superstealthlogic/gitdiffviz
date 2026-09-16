open Semantic_types

module TS = Ts_node.TS

let language = "typescript"

let extensions = [ ".ts"; ".tsx"; ".mts"; ".cts"; ".js"; ".jsx"; ".mjs"; ".cjs" ]

(* tree-sitter-typescript ships two dialects of one grammar. `typescript`
   accepts `<T>expr` type assertions and rejects JSX; `tsx` accepts JSX and
   reads `<T>` as a JSX tag. Plain JavaScript never uses `<T>expr`, so the tsx
   dialect is the better fit for every extension except `.ts`/`.mts`/`.cts`. *)
external create_parser_typescript :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_typescript"

external create_parser_tsx :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_tsx"

let dialect_for_path path =
  match String.lowercase_ascii (Language.extension path) with
  | ".ts" | ".mts" | ".cts" -> `Typescript
  | _ -> `Tsx

(* Bare `const`/`let`/`var` declarations are only emitted as symbols outside
   function bodies, where they are module or namespace level API. *)
type scope =
  | Top_scope
  | Nested_scope

let parse ~path source =
  let parser =
    match dialect_for_path path with
    | `Typescript -> create_parser_typescript ()
    | `Tsx -> create_parser_tsx ()
  in
  let parsed =
    Tree_sitter_run.Tree_sitter_parsing.parse_source_string parser source
  in
  Tree_sitter_run.Tree_sitter_parsing.root parsed

let jsx_node_types =
  [ "jsx_element"; "jsx_self_closing_element"; "jsx_fragment" ]

let function_value_types =
  [ "arrow_function"; "function_expression"; "generator_function" ]

let name_node_types =
  [
    "identifier";
    "type_identifier";
    "property_identifier";
    "private_property_identifier";
    "nested_identifier";
    "shorthand_property_identifier";
  ]

let is_upper_snake name =
  String.length name > 0
  && String.for_all
       (function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
       name

let starts_uppercase name =
  String.length name > 0 && match name.[0] with 'A' .. 'Z' -> true | _ -> false

let strip_quotes value =
  let len = String.length value in
  if len >= 2 then
    match (value.[0], value.[len - 1]) with
    | ('"', '"') | ('\'', '\'') | ('`', '`') -> String.sub value 1 (len - 2)
    | _ -> value
  else value

(* --- modifiers and decorators ---------------------------------------- *)

let decorator_names lines node =
  Ts_node.children node
  |> List.filter (fun (child : TS.node) -> String.equal child.type_ "decorator")
  |> List.map (fun child ->
         let text = Ts_node.trimmed_text lines child in
         let text =
           if String.starts_with ~prefix:"@" text then
             String.sub text 1 (String.length text - 1)
           else text
         in
         let text =
           match String.index_opt text '(' with
           | None -> text
           | Some index -> String.sub text 0 index
         in
         let text = String.trim text in
         match String.rindex_opt text '.' with
         | None -> text
         | Some index ->
             String.sub text (index + 1) (String.length text - index - 1))

(* Framework decorators that say what a class or member *is*. *)
let decorator_semantic decorators =
  if decorators = [] then empty_semantic_properties
  else
    let has name = List.mem name decorators in
    let patterns =
      "decorated"
      :: List.filter_map
           (fun (condition, tag) -> if condition then Some tag else None)
           [
             (has "Component", "component");
             (has "Injectable" || has "Service", "service");
             (has "Controller", "controller");
             (has "Module" || has "NgModule", "module");
             (has "Directive", "directive");
             (has "Pipe", "pipe");
           ]
    in
    { empty_semantic_properties with patterns }

let modifier_semantic node =
  let types = Ts_node.child_types node in
  let has value = List.mem value types in
  let patterns =
    List.filter_map
      (fun (condition, tag) -> if condition then Some tag else None)
      [
        (has "static", "static");
        (has "readonly", "readonly");
        (has "abstract", "abstract");
        (has "override_modifier", "override");
        (has "declare", "ambient");
      ]
  in
  { empty_semantic_properties with patterns }

let async_semantic node =
  if Ts_node.has_child_type [ "async" ] node then
    Symbol_normalization.semantic_tags ~patterns:[ "async" ]
      ~paradigms:[ "async" ] ()
  else empty_semantic_properties

let generic_semantic node =
  if Ts_node.has_child_type [ "type_parameters" ] node then
    Symbol_normalization.generic_semantic ()
  else empty_semantic_properties

let test_semantic =
  Symbol_normalization.semantic_tags ~patterns:[ "test" ] ~paradigms:[ "test" ]

let component_semantic =
  Symbol_normalization.semantic_tags ~patterns:[ "react_component" ]
    ~paradigms:[ "react" ]

let merge_all = List.fold_left merge_semantic_properties empty_semantic_properties

(* --- names ------------------------------------------------------------ *)

let declaration_name lines ~keywords node =
  Ts_node.child_after ~keywords ~types:name_node_types node
  |> Option.map (Ts_node.trimmed_text lines)

(* `get foo()`, `private static readonly bar = 1`, `["computed"]()`: every
   modifier and decorator that can precede a member name is a distinct node
   type, so the member name is the first name-like child. Stop at `=` and at
   the parameter list so an initializer value is never mistaken for a name. *)
let member_name lines node =
  let name_types =
    name_node_types @ [ "string"; "number"; "computed_property_name" ]
  in
  let rec loop = function
    | [] -> None
    | (child : TS.node) :: rest ->
        if List.mem child.TS.type_ name_types then Some child
        else if List.mem child.type_ [ "formal_parameters"; "="; "type_annotation" ]
        then None
        else loop rest
  in
  (* A computed key can hold an arbitrary expression: `[Symbol.iterator]` names
     a member, but downlevelled output puts whole WeakMap initializer chains in
     one. Only read through to a key that could be a name. *)
  let name_of (node : TS.node) =
    if String.equal node.type_ "computed_property_name" then
      Ts_node.first_child_of_type
        [ "string"; "number"; "identifier"; "member_expression" ]
        node
    else Some node
  in
  match loop (Ts_node.children node) with
  | None -> None
  | Some node -> (
      match name_of node with
      | None -> None
      | Some node ->
          let name = Ts_node.trimmed_text lines node |> strip_quotes in
          if String.length name > 0 && not (String.contains name '\n') then
            Some name
          else None)

let module_name lines node =
  Ts_node.child_after
    ~keywords:[ "namespace"; "module"; "global" ]
    ~types:(name_node_types @ [ "string" ])
    node
  |> Option.map (fun node -> Ts_node.trimmed_text lines node |> strip_quotes)

(* --- jest / vitest / mocha blocks ------------------------------------- *)

let test_suite_callees = [ "describe"; "suite"; "context"; "xdescribe"; "fdescribe" ]

let test_case_callees =
  [ "it"; "test"; "xit"; "fit"; "xtest"; "specify"; "bench" ]

let callee_base_name lines (node : TS.node) =
  match node.type_ with
  | "identifier" -> Some (Ts_node.trimmed_text lines node)
  | "member_expression" | "call_expression" ->
      Ts_node.find_first_of_type [ "identifier" ] node
      |> Option.map (Ts_node.trimmed_text lines)
  | _ -> None

let test_block_name lines node =
  match Ts_node.first_child_of_type [ "arguments" ] node with
  | None -> None
  | Some arguments ->
      Ts_node.first_child_of_type [ "string"; "template_string" ] arguments
      |> Option.map (fun node ->
             Ts_node.trimmed_text lines node |> strip_quotes)

(* Returns the symbol kind and language kind when [node] is a test block. *)
let test_block_kind lines (node : TS.node) =
  match Ts_node.children node with
  | callee :: _ -> (
      match callee_base_name lines callee with
      | None -> None
      | Some base ->
          if List.mem base test_suite_callees then
            Some (Type_container, "test_suite")
          else if List.mem base test_case_callees then
            Some (Function, "test_case")
          else None)
  | [] -> None

(* --- symbol construction --------------------------------------------- *)

let make_symbol ~path ~span ~kind ~language_kind ~name ~parents ~semantic =
  let parent_symbol_id =
    match parents with [] -> None | parent_id :: _ -> Some parent_id
  in
  Symbol_normalization.make_symbol ~path ~kind ~language_kind ~name ~span
    ?parent_symbol_id ~semantic ()

let parent_of_symbol (symbol : semantic_symbol) = symbol.id

let is_react_component ~name node =
  starts_uppercase name && Ts_node.exists_descendant jsx_node_types node

let function_like_symbol ~path ~lines ~span ~parents ~language_kind ~keywords node
    =
  match declaration_name lines ~keywords node with
  | None -> None
  | Some name ->
      let is_component = is_react_component ~name node in
      let language_kind = if is_component then "component" else language_kind in
      let semantic =
        merge_all
          [
            decorator_semantic (decorator_names lines node);
            modifier_semantic node;
            async_semantic node;
            generic_semantic node;
            (if is_component then component_semantic () else empty_semantic_properties);
          ]
      in
      Some (make_symbol ~path ~span ~kind:Function ~language_kind ~name ~parents
              ~semantic)

let class_like_symbol ~path ~lines ~span ~parents ~language_kind ~keywords node =
  match declaration_name lines ~keywords node with
  | None -> None
  | Some name ->
      let semantic =
        merge_all
          [
            decorator_semantic (decorator_names lines node);
            modifier_semantic node;
            generic_semantic node;
          ]
      in
      Some
        (make_symbol ~path ~span ~kind:Type_container ~language_kind ~name
           ~parents ~semantic)

let method_language_kind ~name node =
  let types = Ts_node.child_types node in
  if String.equal name "constructor" then "constructor"
  else if List.mem "get" types then "getter"
  else if List.mem "set" types then "setter"
  else if List.mem "*" types then "generator_method"
  else "method"

let method_symbol ~path ~lines ~span ~parents ~language_kind node =
  match member_name lines node with
  | None -> None
  | Some name ->
      let language_kind =
        match language_kind with
        | Some language_kind -> language_kind
        | None -> method_language_kind ~name node
      in
      let semantic =
        merge_all
          [
            decorator_semantic (decorator_names lines node);
            modifier_semantic node;
            async_semantic node;
            generic_semantic node;
          ]
      in
      Some
        (make_symbol ~path ~span ~kind:Function ~language_kind ~name ~parents
           ~semantic)

let field_symbol ~path ~lines ~span ~parents node =
  match member_name lines node with
  | None -> None
  | Some name ->
      (* `handle = () => {...}` is a method in everything but syntax. *)
      let value = Ts_node.first_child_of_type function_value_types node in
      let kind, language_kind =
        match value with
        | Some _ -> (Function, "method")
        | None -> (Symbol, "field")
      in
      let semantic =
        merge_all
          [
            decorator_semantic (decorator_names lines node);
            modifier_semantic node;
            (match value with
            | Some value -> async_semantic value
            | None -> empty_semantic_properties);
          ]
      in
      Some (make_symbol ~path ~span ~kind ~language_kind ~name ~parents ~semantic)

let property_signature_symbol ~path ~lines ~span ~parents node =
  match member_name lines node with
  | None -> None
  | Some name ->
      let is_callable = Ts_node.exists_descendant [ "function_type" ] node in
      let kind, language_kind =
        if is_callable then (Function, "method_signature") else (Symbol, "property")
      in
      Some
        (make_symbol ~path ~span ~kind ~language_kind ~name ~parents
           ~semantic:(modifier_semantic node))

let type_alias_symbol ~path ~lines ~span ~parents node =
  match declaration_name lines ~keywords:[ "type" ] node with
  | None -> None
  | Some name ->
      Some
        (make_symbol ~path ~span ~kind:Symbol ~language_kind:"type_alias" ~name
           ~parents ~semantic:(generic_semantic node))

let module_symbol ~path ~lines ~span ~parents ~language_kind node =
  match module_name lines node with
  | None -> None
  | Some name ->
      Some
        (make_symbol ~path ~span ~kind:Type_container ~language_kind ~name
           ~parents ~semantic:(modifier_semantic node))

(* A `const x = ..., y = ...` declaration carries one declarator per binding. *)
let declarator_symbol ~path ~lines ~span ~scope ~parents declarator =
  let name =
    match Ts_node.children declarator with
    | first :: _ when List.mem first.TS.type_ [ "identifier" ] ->
        Some (Ts_node.trimmed_text lines first)
    | _ -> None
  in
  match name with
  | None -> None
  | Some name -> (
      let value =
        Ts_node.first_child_of_type
          (function_value_types @ [ "class" ])
          declarator
      in
      match value with
      | Some value when List.mem value.TS.type_ function_value_types ->
          let is_component = is_react_component ~name value in
          let language_kind =
            if is_component then "component"
            else if String.equal value.type_ "arrow_function" then "arrow_function"
            else if String.equal value.type_ "generator_function" then
              "generator_function"
            else "function"
          in
          let semantic =
            merge_all
              [
                async_semantic value;
                generic_semantic value;
                (if is_component then component_semantic ()
                 else empty_semantic_properties);
              ]
          in
          Some
            ( make_symbol ~path ~span ~kind:Function ~language_kind ~name ~parents
                ~semantic,
              Some value )
      | Some value when String.equal value.TS.type_ "class" ->
          Some
            ( make_symbol ~path ~span ~kind:Type_container ~language_kind:"class"
                ~name ~parents ~semantic:(generic_semantic value),
              Some value )
      | _ ->
          if scope = Top_scope && is_upper_snake name then
            Some
              ( make_symbol ~path ~span ~kind:Symbol ~language_kind:"constant"
                  ~name ~parents ~semantic:empty_semantic_properties,
                None )
          else None)

(* --- traversal -------------------------------------------------------- *)

let declaration_types =
  [
    "class_declaration";
    "abstract_class_declaration";
    "interface_declaration";
    "enum_declaration";
    "type_alias_declaration";
    "function_declaration";
    "generator_function_declaration";
    "function_signature";
    "internal_module";
    "module";
    "lexical_declaration";
    "variable_declaration";
  ]

let wrapper_types = [ "export_statement"; "ambient_declaration" ]

(* Type positions hold `object_type` members that look like declarations but
   belong to a type, not to the enclosing class or function. Skipping them
   keeps `class Legend extends Component<{ label: string }>` from reporting a
   `label` field, and inline prop types from becoming component members. *)
let opaque_types =
  [
    "class_heritage";
    "extends_clause";
    "extends_type_clause";
    "implements_clause";
    "type_annotation";
    "type_arguments";
    "type_parameters";
    "as_expression";
    "satisfies_expression";
  ]

let rec walk_node ~path ~lines ~scope ~parents ?span ?(in_interface = false) node =
  let span = Option.value span ~default:(Ts_node.node_span node) in
  let recurse_children ?(in_interface = false) ~scope ~parents node =
    walk_children ~path ~lines ~scope ~parents ~in_interface
      (Ts_node.children node)
  in
  let simple ~symbol ~scope node =
    (* Emit [symbol], then walk the node's body underneath it. *)
    let child_parents =
      match symbol with
      | Some symbol -> parent_of_symbol symbol :: parents
      | None -> parents
    in
    let nested = recurse_children ~scope ~parents:child_parents node in
    match symbol with None -> nested | Some symbol -> symbol :: nested
  in
  match node.TS.type_ with
  | type_ when List.mem type_ opaque_types -> []
  (* Members are only real when they sit directly in an interface body. *)
  | "interface_body" -> recurse_children ~in_interface:true ~scope ~parents node
  (* `export`/`declare` are transparent, but they donate their span so a diff
     touching the `export` line still lands on the declaration. *)
  | type_ when List.mem type_ wrapper_types -> (
      match Ts_node.first_child_of_type declaration_types node with
      | Some declaration ->
          walk_node ~path ~lines ~scope ~parents ~span declaration
      | None -> recurse_children ~scope ~parents node)
  | "class_declaration" | "abstract_class_declaration" ->
      let language_kind =
        if String.equal node.type_ "abstract_class_declaration" then
          "abstract_class"
        else "class"
      in
      let symbol =
        class_like_symbol ~path ~lines ~span ~parents ~language_kind
          ~keywords:[ "class" ] node
      in
      simple ~symbol ~scope:Nested_scope node
  | "interface_declaration" ->
      let symbol =
        class_like_symbol ~path ~lines ~span ~parents ~language_kind:"interface"
          ~keywords:[ "interface" ] node
      in
      simple ~symbol ~scope:Nested_scope node
  | "enum_declaration" ->
      let symbol =
        class_like_symbol ~path ~lines ~span ~parents ~language_kind:"enum"
          ~keywords:[ "enum" ] node
      in
      simple ~symbol ~scope:Nested_scope node
  | "internal_module" | "module" ->
      let language_kind =
        if String.equal node.type_ "module" then "module" else "namespace"
      in
      let symbol = module_symbol ~path ~lines ~span ~parents ~language_kind node in
      (* Namespace bodies are top level for the declarations they contain. *)
      simple ~symbol ~scope:Top_scope node
  | "function_declaration" | "generator_function_declaration" | "function_signature"
    ->
      let language_kind =
        match node.type_ with
        | "generator_function_declaration" -> "generator_function"
        | "function_signature" -> "function_signature"
        | _ -> "function"
      in
      let symbol =
        function_like_symbol ~path ~lines ~span ~parents ~language_kind
          ~keywords:[ "function" ] node
      in
      simple ~symbol ~scope:Nested_scope node
  | "method_definition" ->
      let symbol = method_symbol ~path ~lines ~span ~parents ~language_kind:None node in
      simple ~symbol ~scope:Nested_scope node
  | "method_signature" when in_interface ->
      let symbol =
        method_symbol ~path ~lines ~span ~parents
          ~language_kind:(Some "method_signature") node
      in
      simple ~symbol ~scope:Nested_scope node
  | "method_signature" -> []
  | "abstract_method_signature" ->
      let symbol =
        method_symbol ~path ~lines ~span ~parents
          ~language_kind:(Some "abstract_method") node
      in
      simple ~symbol ~scope:Nested_scope node
  | "public_field_definition" ->
      let symbol = field_symbol ~path ~lines ~span ~parents node in
      simple ~symbol ~scope:Nested_scope node
  | "property_signature" when in_interface -> (
      match property_signature_symbol ~path ~lines ~span ~parents node with
      | None -> []
      | Some symbol -> [ symbol ])
  | "property_signature" -> []
  | "type_alias_declaration" -> (
      match type_alias_symbol ~path ~lines ~span ~parents node with
      | None -> []
      | Some symbol -> [ symbol ])
  | "lexical_declaration" | "variable_declaration" ->
      let declarators =
        Ts_node.children node
        |> List.filter (fun (child : TS.node) ->
               String.equal child.type_ "variable_declarator")
      in
      (* With a single binding the whole statement is the symbol's span, so the
         `export const` line is included; with several, each gets its own. *)
      let single = match declarators with [ _ ] -> true | _ -> false in
      declarators
      |> List.concat_map (fun declarator ->
             let span =
               if single then span else Ts_node.node_span declarator
             in
             match
               declarator_symbol ~path ~lines ~span ~scope ~parents declarator
             with
             | None -> recurse_children ~scope:Nested_scope ~parents declarator
             | Some (symbol, body) ->
                 let child_parents = parent_of_symbol symbol :: parents in
                 let nested =
                   match body with
                   | None -> []
                   | Some body ->
                       recurse_children ~scope:Nested_scope ~parents:child_parents
                         body
                 in
                 symbol :: nested)
  | "call_expression" -> (
      match test_block_kind lines node with
      | None -> recurse_children ~scope ~parents node
      | Some (kind, language_kind) -> (
          match test_block_name lines node with
          | None -> recurse_children ~scope ~parents node
          | Some name ->
              let symbol =
                make_symbol ~path ~span ~kind ~language_kind ~name ~parents
                  ~semantic:(test_semantic ())
              in
              let child_parents = parent_of_symbol symbol :: parents in
              symbol
              :: recurse_children ~scope:Nested_scope ~parents:child_parents node))
  | _ -> recurse_children ~scope ~parents node

and walk_children ~path ~lines ~scope ~parents ~in_interface nodes =
  nodes |> List.concat_map (walk_node ~path ~lines ~scope ~parents ~in_interface)

let extract ~repo_root:_ ~path ~source =
  let lines = Ts_node.lines source in
  let root = parse ~path source in
  Ok
    (walk_node ~path ~lines ~scope:Top_scope ~parents:[] root
    |> Symbol_normalization.sort_symbols)
