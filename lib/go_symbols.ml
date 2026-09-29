open Semantic_types

module TS = Ts_node.TS

let language = "go"
let extensions = [ ".go" ]

external create_parser :
  unit -> Tree_sitter_bindings.Tree_sitter_API.ts_parser
  = "gvd_create_parser_go"

(* Constants and variables are only interesting as symbols at file scope. *)
type scope =
  | File_scope
  | Function_scope

type env = {
  parents : string list;
  scope : scope;
  (* Set inside the body of a test, benchmark or fuzz function, where a
     `t.Run("name", func(t *testing.T) {...})` call is a subtest. *)
  in_test : bool;
}

type context = {
  path : string;
  lines : string array;
  is_test_file : bool;
  is_main_package : bool;
}

(* Go attaches methods and iota constants to a type declared elsewhere in the
   file rather than lexically inside it, so those edges are resolved after the
   whole file has been walked. *)
type pending = {
  symbol : semantic_symbol;
  receiver_type : string option;
  enum_type : string option;
}

let parse source =
  let parser = create_parser () in
  let parsed =
    Tree_sitter_run.Tree_sitter_parsing.parse_source_string parser source
  in
  Tree_sitter_run.Tree_sitter_parsing.root parsed

let plain symbol = { symbol; receiver_type = None; enum_type = None }

let is_upper = function 'A' .. 'Z' -> true | _ -> false

(* Go's visibility rule: an identifier is exported iff it starts upper case.
   Changing one is an API-visible change, so it is worth carrying in a diff. *)
let is_exported name = String.length name > 0 && is_upper name.[0]

let exported_patterns name = if is_exported name then [ "exported" ] else []

let tags ?(patterns = []) ?(paradigms = []) () =
  Symbol_normalization.semantic_tags ~patterns ~paradigms ()

let type_node_types = [ "type_identifier"; "qualified_type"; "generic_type" ]

let make ~ctx ~kind ~language_kind ~name ~span ~parents ~semantic =
  let parent_symbol_id =
    match parents with [] -> None | parent_id :: _ -> Some parent_id
  in
  Symbol_normalization.make_symbol ~path:ctx.path ~kind ~language_kind ~name
    ~span ?parent_symbol_id ~semantic ()

let parent_of (symbol : semantic_symbol) = symbol.id

let span_of ?doc_row (node : TS.node) =
  let start_row =
    match doc_row with
    | Some row -> min row node.TS.start_pos.row
    | None -> node.TS.start_pos.row
  in
  Symbol_normalization.source_span ~start_row ~end_row:node.TS.end_pos.row

(* A Go doc comment sits immediately above the declaration it documents and is
   part of that declaration's public surface, so the declaration claims the
   adjacent comment block: a diff that only rewrites the doc still maps to the
   symbol rather than stopping at the file. *)
let with_doc_rows nodes =
  let rec loop pending acc = function
    | [] -> List.rev acc
    | (node : TS.node) :: rest ->
        if String.equal node.type_ "comment" then
          let pending =
            match pending with
            | Some (start_row, end_row) when end_row + 1 = node.start_pos.row ->
                Some (start_row, node.end_pos.row)
            | _ -> Some (node.start_pos.row, node.end_pos.row)
          in
          loop pending acc rest
        else
          let doc_row =
            match pending with
            | Some (start_row, end_row) when end_row + 1 = node.start_pos.row ->
                Some start_row
            | _ -> None
          in
          loop None ((node, doc_row) :: acc) rest
  in
  loop None [] nodes

let children_of_type types node =
  Ts_node.children node
  |> List.filter (fun (child : TS.node) -> List.mem child.type_ types)

let text ctx node = Ts_node.trimmed_text ctx.lines node

(* The unqualified type name, which is also the field name Go gives an embedded
   field: `*sync.Mutex` is reached as the field `Mutex`. *)
let unqualified_type_name ctx node =
  Ts_node.find_first_of_type [ "type_identifier" ] node |> Option.map (text ctx)

let string_literal_value ctx (node : TS.node) =
  match node.type_ with
  | "interpreted_string_literal" | "raw_string_literal" -> (
      match
        Ts_node.first_child_of_type
          [ "interpreted_string_literal_content"; "raw_string_literal_content" ]
          node
      with
      | None -> None
      | Some content ->
          let value = Ts_node.text_of_node ctx.lines content in
          if String.equal (String.trim value) "" then None else Some value)
  | _ -> None

let filter_tags entries =
  List.filter_map (fun (present, tag) -> if present then Some tag else None) entries

(* Concurrency is Go's defining paradigm; a diff reader wants to know that a
   function spawns goroutines or talks over channels. *)
let concurrency_patterns node =
  filter_tags
    [
      (Ts_node.exists_descendant [ "go_statement" ] node, "goroutine");
      (Ts_node.exists_descendant [ "select_statement" ] node, "select");
      ( Ts_node.exists_descendant [ "channel_type"; "send_statement" ] node,
        "channel" );
    ]

let concurrency_paradigms patterns =
  if patterns = [] then [] else [ "concurrent" ]

(* Method names that, by convention, mean the receiver implements a standard
   library interface. *)
let method_role = function
  | "String" -> Some "stringer"
  | "Error" -> Some "error_interface"
  | "ServeHTTP" -> Some "http_handler"
  | "MarshalJSON" -> Some "json_marshaler"
  | "UnmarshalJSON" -> Some "json_unmarshaler"
  | "Close" -> Some "closer"
  | _ -> None

(* `NewWidget` is Go's constructor idiom. *)
let is_constructor name =
  String.starts_with ~prefix:"New" name
  && (String.length name = 3 || is_upper name.[3])

let has_type_parameters node = Ts_node.has_child_type [ "type_parameter_list" ] node

let generic_patterns node = if has_type_parameters node then [ "generic" ] else []
let generic_paradigms node = if has_type_parameters node then [ "generic" ] else []

(* `go test` only treats `TestXxx` as a test when the character after the prefix
   is not lower case. *)
let has_test_prefix ~prefix name =
  String.starts_with ~prefix name
  && (String.length name = String.length prefix
     || not (match name.[String.length prefix] with 'a' .. 'z' -> true | _ -> false))

let contains ~needle haystack =
  let needle_length = String.length needle in
  let limit = String.length haystack - needle_length in
  let rec loop index =
    index <= limit
    && (String.equal (String.sub haystack index needle_length) needle
       || loop (index + 1))
  in
  needle_length > 0 && loop 0

(* A test-shaped name only makes a test when it is in a _test.go file or carries
   the matching `testing` parameter. *)
let test_kind ~ctx ~name ~params_text =
  let signature marker = contains ~needle:marker params_text in
  if has_test_prefix ~prefix:"Test" name && (ctx.is_test_file || signature "testing.T")
  then Some ("test_function", [ "test" ])
  else if
    has_test_prefix ~prefix:"Benchmark" name
    && (ctx.is_test_file || signature "testing.B")
  then Some ("benchmark_function", [ "test"; "benchmark" ])
  else if
    has_test_prefix ~prefix:"Fuzz" name && (ctx.is_test_file || signature "testing.F")
  then Some ("fuzz_function", [ "test"; "fuzz" ])
  else if has_test_prefix ~prefix:"Example" name && ctx.is_test_file then
    Some ("example_function", [ "test"; "example" ])
  else None

let field_symbols_of_struct ~ctx ~parents struct_node =
  let rec field_list ~parents node =
    match Ts_node.first_child_of_type [ "field_declaration_list" ] node with
    | None -> []
    | Some list ->
        with_doc_rows (Ts_node.children list)
        |> List.concat_map (fun ((child : TS.node), doc_row) ->
               if String.equal child.type_ "field_declaration" then
                 field ~parents ?doc_row child
               else [])
  and field ~parents ?doc_row node =
    let span = span_of ?doc_row node in
    match children_of_type [ "field_identifier" ] node with
    | [] -> (
        (* No name: an embedded field, which is how Go composes types. *)
        match Ts_node.first_child_of_type type_node_types node with
        | None -> []
        | Some type_node -> (
            match unqualified_type_name ctx type_node with
            | None -> []
            | Some name ->
                [
                  plain
                    (make ~ctx ~kind:Symbol ~language_kind:"embedded_field" ~name
                       ~span ~parents
                       ~semantic:
                         (tags
                            ~patterns:("embedding" :: exported_patterns name)
                            ~paradigms:[ "composition" ] ()));
                ]))
    | names ->
        let symbols =
          names
          |> List.map (fun name_node ->
                 let name = text ctx name_node in
                 make ~ctx ~kind:Symbol ~language_kind:"field" ~name ~span
                   ~parents
                   ~semantic:(tags ~patterns:(exported_patterns name) ()))
        in
        let nested =
          (* An anonymous struct field declares fields of its own. *)
          match (symbols, Ts_node.first_child_of_type [ "struct_type" ] node) with
          | [ symbol ], Some nested_struct ->
              field_list ~parents:(parent_of symbol :: parents) nested_struct
          | _ -> []
        in
        List.map plain symbols @ nested
  in
  field_list ~parents struct_node

(* An interface element that is a single named type is an embedded interface;
   anything else (a union, an approximation such as `~int`) makes this a generic
   type constraint rather than a behavioural interface. *)
let interface_element_kind (node : TS.node) =
  match Ts_node.children node with
  | [ single ] when List.mem single.TS.type_ type_node_types -> `Embedded single
  | _ -> `Type_set

let interface_symbols ~ctx ~parents interface_node =
  with_doc_rows (Ts_node.children interface_node)
  |> List.concat_map (fun ((child : TS.node), doc_row) ->
         let span = span_of ?doc_row child in
         match child.type_ with
         | "method_elem" -> (
             match Ts_node.first_child_of_type [ "field_identifier" ] child with
             | None -> []
             | Some name_node ->
                 let name = text ctx name_node in
                 let patterns =
                   (method_role name |> Option.to_list) @ exported_patterns name
                 in
                 [
                   plain
                     (make ~ctx ~kind:Function ~language_kind:"interface_method"
                        ~name ~span ~parents ~semantic:(tags ~patterns ()));
                 ])
         | "type_elem" -> (
             match interface_element_kind child with
             | `Type_set -> []
             | `Embedded type_node -> (
                 match unqualified_type_name ctx type_node with
                 | None -> []
                 | Some name ->
                     [
                       plain
                         (make ~ctx ~kind:Symbol
                            ~language_kind:"embedded_interface" ~name ~span
                            ~parents
                            ~semantic:
                              (tags
                                 ~patterns:("embedding" :: exported_patterns name)
                                 ~paradigms:[ "composition" ] ()));
                     ]))
         | _ -> [])

let interface_is_constraint interface_node =
  children_of_type [ "type_elem" ] interface_node
  |> List.exists (fun child -> interface_element_kind child = `Type_set)

(* `type Widget struct {...}` / `type Mode int` / `type Transform func(...)`. *)
let type_spec ~ctx ~env ?doc_row node =
  match Ts_node.first_child_of_type [ "type_identifier" ] node with
  | None -> []
  | Some name_node ->
      let name = text ctx name_node in
      let span = span_of ?doc_row node in
      let struct_node = Ts_node.first_child_of_type [ "struct_type" ] node in
      let interface_node = Ts_node.first_child_of_type [ "interface_type" ] node in
      let function_node = Ts_node.first_child_of_type [ "function_type" ] node in
      let kind, language_kind, patterns =
        match (struct_node, interface_node, function_node) with
        | Some _, _, _ -> (Type_container, "struct", [])
        | _, Some interface_node, _ ->
            ( Type_container,
              "interface",
              if interface_is_constraint interface_node then [ "constraint" ]
              else [] )
        | _, _, Some _ -> (Symbol, "func_type", [])
        (* A defined type such as `type Mode int` still owns a method set. *)
        | None, None, None -> (Type_container, "type", [])
      in
      let semantic =
        tags
          ~patterns:(patterns @ generic_patterns node @ exported_patterns name)
          ~paradigms:(generic_paradigms node)
          ()
      in
      let symbol =
        make ~ctx ~kind ~language_kind ~name ~span ~parents:env.parents ~semantic
      in
      let parents = parent_of symbol :: env.parents in
      let members =
        match (struct_node, interface_node) with
        | Some struct_node, _ -> field_symbols_of_struct ~ctx ~parents struct_node
        | _, Some interface_node -> interface_symbols ~ctx ~parents interface_node
        | None, None -> []
      in
      plain symbol :: members

let type_alias ~ctx ~env ?doc_row node =
  match Ts_node.first_child_of_type [ "type_identifier" ] node with
  | None -> []
  | Some name_node ->
      let name = text ctx name_node in
      [
        plain
          (make ~ctx ~kind:Symbol ~language_kind:"type_alias" ~name
             ~span:(span_of ?doc_row node) ~parents:env.parents
             ~semantic:(tags ~patterns:(exported_patterns name) ()));
      ]

(* `var ErrMissing = errors.New(...)` is Go's sentinel error idiom. *)
let is_sentinel_error name =
  String.starts_with ~prefix:"Err" name
  && (String.length name = 3 || is_upper name.[3])
  || String.starts_with ~prefix:"err" name
     && String.length name > 3
     && is_upper name.[3]

let value_spec_symbols ~ctx ~env ~language_kind ~enum_type ?doc_row node =
  let span = span_of ?doc_row node in
  children_of_type [ "identifier" ] node
  |> List.map (fun name_node ->
         let name = text ctx name_node in
         let patterns =
           (if String.equal language_kind "variable" && is_sentinel_error name then
              [ "sentinel_error" ]
            else [])
           @ exported_patterns name
         in
         {
           symbol =
             make ~ctx ~kind:Symbol ~language_kind ~name ~span
               ~parents:env.parents ~semantic:(tags ~patterns ());
           receiver_type = None;
           enum_type;
         })

(* `var (...)` wraps its specs in a `var_spec_list`; `const (...)` holds them
   directly. *)
let value_specs ~spec_type node =
  let of_parent parent =
    with_doc_rows (Ts_node.children parent)
    |> List.filter (fun ((child : TS.node), _) ->
           String.equal child.type_ spec_type)
  in
  match Ts_node.first_child_of_type [ spec_type ^ "_list" ] node with
  | Some list -> of_parent list
  | None -> of_parent node

(* A parenthesised `const` block using `iota` is how Go spells an enumeration.
   Only the first spec usually carries the type, and the rest inherit it. *)
let const_declaration ~ctx ~env ?doc_row node =
  let is_enum_block = Ts_node.exists_descendant [ "iota" ] node in
  let specs = value_specs ~spec_type:"const_spec" node in
  let single = match specs with [ _ ] -> true | _ -> false in
  let rec loop inherited acc = function
    | [] -> List.rev acc
    | ((spec : TS.node), spec_doc_row) :: rest ->
        let declared =
          Ts_node.first_child_of_type type_node_types spec
          |> Option.map (fun type_node -> text ctx type_node)
        in
        let current = match declared with Some _ -> declared | None -> inherited in
        let enum_type = if is_enum_block then current else None in
        let language_kind =
          match enum_type with Some _ -> "enum_constant" | None -> "constant"
        in
        let doc_row = if single then doc_row else spec_doc_row in
        let symbols =
          value_spec_symbols ~ctx ~env ~language_kind ~enum_type ?doc_row spec
        in
        loop current (List.rev_append symbols acc) rest
  in
  loop None [] specs

let var_declaration ~ctx ~env ?doc_row node =
  let specs = value_specs ~spec_type:"var_spec" node in
  let single = match specs with [ _ ] -> true | _ -> false in
  specs
  |> List.concat_map (fun ((spec : TS.node), spec_doc_row) ->
         let doc_row = if single then doc_row else spec_doc_row in
         value_spec_symbols ~ctx ~env ~language_kind:"variable" ~enum_type:None
           ?doc_row spec)

let parameter_list_text ctx node =
  Ts_node.first_child_of_type [ "parameter_list" ] node
  |> Option.map (text ctx)
  |> Option.value ~default:""

let function_declaration ~ctx ~env ?doc_row node =
  match Ts_node.child_after ~keywords:[ "func" ] ~types:[ "identifier" ] node with
  | None -> None
  | Some name_node ->
      let name = text ctx name_node in
      let params_text = parameter_list_text ctx node in
      let test = test_kind ~ctx ~name ~params_text in
      let language_kind, test_patterns =
        match test with
        | Some (language_kind, patterns) -> (language_kind, patterns)
        | None ->
            if String.equal name "init" && String.equal params_text "()" then
              ("init_function", [ "init" ])
            else ("function", [])
      in
      let concurrency = concurrency_patterns node in
      let patterns =
        test_patterns
        @ filter_tags
            [
              (is_constructor name, "constructor");
              (ctx.is_main_package && String.equal name "main", "entrypoint");
            ]
        @ concurrency @ generic_patterns node
        (* A test's name is always exported; saying so adds nothing. *)
        @ (if Option.is_some test then [] else exported_patterns name)
      in
      let paradigms =
        (if Option.is_some test then [ "test" ] else [])
        @ concurrency_paradigms concurrency
        @ generic_paradigms node
      in
      let symbol =
        make ~ctx ~kind:Function ~language_kind ~name ~span:(span_of ?doc_row node)
          ~parents:env.parents
          ~semantic:(tags ~patterns ~paradigms ())
      in
      Some (symbol, Option.is_some test)

(* Methods are named the way Go names them everywhere else - `Widget.Resize` in
   `go doc`, and receiver-qualified in a stack trace - because the receiver is
   what makes the name unambiguous when the type is declared in another file. *)
let method_declaration ~ctx ~env ?doc_row node =
  let receiver = Ts_node.first_child_of_type [ "parameter_list" ] node in
  let receiver_type =
    Option.bind receiver (fun receiver ->
        Ts_node.find_first_of_type [ "type_identifier" ] receiver
        |> Option.map (text ctx))
  in
  match Ts_node.first_child_of_type [ "field_identifier" ] node with
  | None -> None
  | Some name_node ->
      let method_name = text ctx name_node in
      let name =
        match receiver_type with
        | Some receiver_type -> receiver_type ^ "." ^ method_name
        | None -> method_name
      in
      let is_pointer =
        match receiver with
        | Some receiver -> Ts_node.exists_descendant [ "pointer_type" ] receiver
        | None -> false
      in
      let concurrency = concurrency_patterns node in
      let patterns =
        (method_role method_name |> Option.to_list)
        @ [ (if is_pointer then "pointer_receiver" else "value_receiver") ]
        @ concurrency
        @ exported_patterns method_name
      in
      let symbol =
        make ~ctx ~kind:Function ~language_kind:"method" ~name
          ~span:(span_of ?doc_row node) ~parents:env.parents
          ~semantic:
            (tags ~patterns ~paradigms:(concurrency_paradigms concurrency) ())
      in
      Some { (plain symbol) with receiver_type }

(* `t.Run("name", func(t *testing.T) {...})` - Go's subtest, and the unit a
   table-driven test actually fails in. *)
let subtest ~ctx ~env node =
  let selector = Ts_node.first_child_of_type [ "selector_expression" ] node in
  let is_run =
    match Option.bind selector (Ts_node.first_child_of_type [ "field_identifier" ]) with
    | Some field -> String.equal (text ctx field) "Run"
    | None -> false
  in
  if not is_run then None
  else
    match Ts_node.first_child_of_type [ "argument_list" ] node with
    | None -> None
    | Some arguments -> (
        let name =
          Ts_node.children arguments |> List.find_map (string_literal_value ctx)
        in
        let body = Ts_node.first_child_of_type [ "func_literal" ] arguments in
        match (name, body) with
        | Some name, Some body ->
            let symbol =
              make ~ctx ~kind:Function ~language_kind:"test_case" ~name
                ~span:(span_of node) ~parents:env.parents
                ~semantic:(tags ~patterns:[ "test" ] ~paradigms:[ "test" ] ())
            in
            Some (symbol, body)
        | _ -> None)

let rec walk ~ctx ~env ?doc_row (node : TS.node) =
  match node.type_ with
  | "type_declaration" -> (
      (* A lone spec inherits the declaration's doc comment; inside a grouped
         `type (...)` block each spec carries its own. *)
      match children_of_type [ "type_spec"; "type_alias" ] node with
      | [ spec ] -> walk ~ctx ~env ?doc_row spec
      | _ -> walk_children ~ctx ~env node)
  | "type_spec" -> type_spec ~ctx ~env ?doc_row node
  | "type_alias" -> type_alias ~ctx ~env ?doc_row node
  | "const_declaration" ->
      if env.scope = File_scope then const_declaration ~ctx ~env ?doc_row node
      else []
  | "var_declaration" ->
      if env.scope = File_scope then var_declaration ~ctx ~env ?doc_row node
      else []
  | "function_declaration" -> (
      match function_declaration ~ctx ~env ?doc_row node with
      | None -> []
      | Some (symbol, in_test) ->
          plain symbol :: walk_body ~ctx ~symbol ~in_test node)
  | "method_declaration" -> (
      match method_declaration ~ctx ~env ?doc_row node with
      | None -> []
      | Some pending ->
          pending :: walk_body ~ctx ~symbol:pending.symbol ~in_test:false node)
  | "call_expression" when env.in_test -> (
      match subtest ~ctx ~env node with
      | None -> walk_children ~ctx ~env node
      | Some (symbol, body) ->
          plain symbol :: walk_body ~ctx ~symbol ~in_test:true body)
  | _ -> walk_children ~ctx ~env node

and walk_body ~ctx ~symbol ~in_test node =
  walk_children ~ctx
    ~env:{ parents = [ parent_of symbol ]; scope = Function_scope; in_test }
    node

and walk_children ~ctx ~env node =
  with_doc_rows (Ts_node.children node)
  |> List.concat_map (fun (child, doc_row) -> walk ~ctx ~env ?doc_row child)

(* Attach methods to their receiver's type and iota constants to the type that
   names them, and mark that type as an enumeration. A receiver type declared
   *after* its methods is left unattached: the downstream hierarchy join adds a
   symbol to its parent as it walks the file in span order. *)
let resolve pendings =
  let type_symbols =
    pendings
    |> List.filter_map (fun pending ->
           match (pending.symbol.kind, pending.symbol.parent_symbol_id) with
           | Type_container, None -> Some (pending.symbol.name, pending.symbol)
           | _ -> None)
  in
  let owner name (symbol : semantic_symbol) =
    match List.assoc_opt name type_symbols with
    | Some (owner : semantic_symbol)
      when owner.span.start_line < symbol.span.start_line ->
        Some owner
    | _ -> None
  in
  let enum_type_names =
    pendings
    |> List.filter_map (fun pending ->
           match pending.enum_type with
           | Some name -> Option.map (fun _ -> name) (owner name pending.symbol)
           | None -> None)
  in
  pendings
  |> List.map (fun pending ->
         let symbol = pending.symbol in
         let attach name =
           match owner name symbol with
           | Some owner -> { symbol with parent_symbol_id = Some owner.id }
           | None -> symbol
         in
         let symbol =
           match (pending.receiver_type, pending.enum_type) with
           | Some receiver_type, _ -> attach receiver_type
           | _, Some enum_type -> attach enum_type
           | None, None -> symbol
         in
         if
           symbol.kind = Type_container
           && Option.is_none symbol.parent_symbol_id
           && List.mem symbol.name enum_type_names
         then
           {
             symbol with
             semantic =
               merge_semantic_properties
                 (tags ~patterns:[ "enum" ] ())
                 symbol.semantic;
           }
         else symbol)

let package_name lines root =
  match Ts_node.find_first_of_type [ "package_identifier" ] root with
  | Some node -> Ts_node.trimmed_text lines node
  | None -> ""

let extract ~repo_root:_ ~path ~source =
  let lines = Ts_node.lines source in
  let root = parse source in
  let is_test_file =
    String.ends_with ~suffix:"_test.go" (Filename.basename path)
  in
  let ctx =
    {
      path;
      lines;
      is_test_file;
      is_main_package = String.equal (package_name lines root) "main";
    }
  in
  let env = { parents = []; scope = File_scope; in_test = false } in
  Ok (walk_children ~ctx ~env root |> resolve |> Symbol_normalization.sort_symbols)
