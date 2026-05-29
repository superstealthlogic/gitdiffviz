open Git_visualization_diff

let fixture_path name =
  let candidates =
    [
      Filename.concat "examples" name;
      Filename.concat "../examples" name;
      Filename.concat "../../examples" name;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> failwith ("fixture not found: " ^ name)

let test_fixture_path name =
  let candidates =
    [
      Filename.concat "test/fixtures" name;
      Filename.concat "fixtures" name;
      Filename.concat "../test/fixtures" name;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> failwith ("test fixture not found: " ^ name)

let snapshot_path name =
  let candidates =
    [
      Filename.concat "test/snapshots" name;
      Filename.concat "snapshots" name;
      Filename.concat "../test/snapshots" name;
      Filename.concat "../../test/snapshots" name;
      Filename.concat "../../../test/snapshots" name;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> failwith ("snapshot not found: " ^ name)

let read_diff_fixture () =
  match Json_codec.read_json_file (fixture_path "sample-diff.json") with
  | Error message -> failwith message
  | Ok json -> (
      match Json_codec.git_diff_document_of_yojson json with
      | Error message -> failwith message
      | Ok diff -> diff)

let read_semantic_fixture () =
  match Json_codec.read_json_file (fixture_path "sample-semantic-input.json") with
  | Error message -> failwith message
  | Ok json -> (
      match Json_codec.semantic_input_document_of_yojson json with
      | Error message -> failwith message
      | Ok semantic -> semantic)

let test_diff_fixture_round_trip () =
  let diff = read_diff_fixture () in
  Alcotest.(check int) "file count" 2 (List.length diff.files);
  Alcotest.(check int) "additions" 18 diff.summary.total_additions;
  let json = Json_codec.git_diff_document_to_yojson diff in
  match Json_codec.git_diff_document_of_yojson json with
  | Error message -> Alcotest.fail message
  | Ok reparsed ->
      Alcotest.(check int) "reparsed file count" 2 (List.length reparsed.files)

let test_hierarchy_from_fixture () =
  let hierarchy = Hierarchy.build (read_diff_fixture ()) in
  Alcotest.(check int) "nodes" 4 hierarchy.metrics.total_nodes;
  Alcotest.(check int) "files" 2 hierarchy.metrics.total_files;
  let root = List.find (fun node -> String.equal node.Hierarchy_types.id "repo") hierarchy.nodes in
  Alcotest.(check (list string)) "root children" [ "dir:src" ] root.children

let test_semantic_join_from_fixture () =
  let diff = read_diff_fixture () in
  let hierarchy = Hierarchy.build diff in
  let semantic = read_semantic_fixture () in
  let semantic_hierarchy =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  Alcotest.(check int) "symbol nodes" 3 semantic_hierarchy.metrics.symbol_nodes;
  let functions =
    List.filter
      (fun node ->
        match node.Semantic_types.kind with
        | Semantic_types.Semantic_symbol Semantic_types.Function -> true
        | _ -> false)
      semantic_hierarchy.nodes
  in
  Alcotest.(check int) "function nodes" 2 (List.length functions)

let semantic_symbol_node_by_source_id source_id document =
  List.find
    (fun (node : Semantic_types.semantic_hierarchy_node) ->
      node.source_symbol_id = Some source_id)
    document.Semantic_types.nodes

let test_semantic_join_precise_hunk_overlap () =
  let hunk =
    Diff_types.
      {
        old_range = { start_line = 10; line_count = 4 };
        new_range = { start_line = 10; line_count = 4 };
        header = "@@ -10,4 +10,4 @@";
        lines =
          Some
            [
              { kind = Context; old_line = Some 10; new_line = Some 10; content = "fn value() {" };
              { kind = Deletion; old_line = Some 11; new_line = None; content = "  old();" };
              { kind = Addition; old_line = None; new_line = Some 11; content = "  new();" };
              { kind = Context; old_line = Some 12; new_line = Some 12; content = "}" };
            ];
      }
  in
  let diff =
    Diff_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        comparison = { base = "base"; target = "target" };
        path_filter = None;
        files =
          [
            {
              path = "src/lib.rs";
              old_path = None;
              status = Modified;
              additions = 1;
              deletions = 1;
              is_binary = false;
              hunks = [ hunk ];
            };
          ];
        summary = { changed_files = 1; total_additions = 1; total_deletions = 1 };
      }
  in
  let hierarchy = Hierarchy.build diff in
  let semantic =
    Semantic_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        files =
          [
            {
              path = "src/lib.rs";
              language = "rust";
              symbols =
                [
                  {
                    id = "value";
                    kind = Function;
                    language_kind = Some "function";
                    name = "value";
                    span = { start_line = 10; end_line = 12 };
                    parent_symbol_id = None;
                    semantic = empty_semantic_properties;
                  };
                ];
            };
          ];
      }
  in
  let document =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  let symbol = semantic_symbol_node_by_source_id "value" document in
  Alcotest.(check int) "precise additions" 1 symbol.diff.lines_added;
  Alcotest.(check int) "precise deletions" 1 symbol.diff.lines_removed

let test_semantic_join_deletion_only_projection () =
  let hunk =
    Diff_types.
      {
        old_range = { start_line = 45; line_count = 2 };
        new_range = { start_line = 51; line_count = 0 };
        header = "@@ -45,2 +51,0 @@";
        lines =
          Some
            [
              { kind = Deletion; old_line = Some 45; new_line = None; content = "  removed_a();" };
              { kind = Deletion; old_line = Some 46; new_line = None; content = "  removed_b();" };
            ];
      }
  in
  let diff =
    Diff_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        comparison = { base = "base"; target = "target" };
        path_filter = None;
        files =
          [
            {
              path = "src/lib.rs";
              old_path = None;
              status = Modified;
              additions = 0;
              deletions = 2;
              is_binary = false;
              hunks = [ hunk ];
            };
          ];
        summary = { changed_files = 1; total_additions = 0; total_deletions = 2 };
      }
  in
  let hierarchy = Hierarchy.build diff in
  let semantic =
    Semantic_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        files =
          [
            {
              path = "src/lib.rs";
              language = "rust";
              symbols =
                [
                  {
                    id = "owner";
                    kind = Function;
                    language_kind = Some "function";
                    name = "owner";
                    span = { start_line = 50; end_line = 55 };
                    parent_symbol_id = None;
                    semantic = empty_semantic_properties;
                  };
                ];
            };
          ];
      }
  in
  let document =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  let symbol = semantic_symbol_node_by_source_id "owner" document in
  Alcotest.(check int) "deletion-only additions" 0 symbol.diff.lines_added;
  Alcotest.(check int) "deletion-only projected deletions" 2
    symbol.diff.lines_removed

let test_semantic_join_renamed_file_old_path_symbols () =
  let diff =
    Diff_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        comparison = { base = "base"; target = "target" };
        path_filter = None;
        files =
          [
            {
              path = "src/new_name.rs";
              old_path = Some "src/old_name.rs";
              status = Renamed;
              additions = 1;
              deletions = 1;
              is_binary = false;
              hunks =
                [
                  {
                    old_range = { start_line = 2; line_count = 2 };
                    new_range = { start_line = 2; line_count = 2 };
                    header = "@@ -2,2 +2,2 @@";
                    lines =
                      Some
                        [
                          {
                            kind = Deletion;
                            old_line = Some 2;
                            new_line = None;
                            content = "  old();";
                          };
                          {
                            kind = Addition;
                            old_line = None;
                            new_line = Some 2;
                            content = "  new();";
                          };
                        ];
                  };
                ];
            };
          ];
        summary = { changed_files = 1; total_additions = 1; total_deletions = 1 };
      }
  in
  let hierarchy = Hierarchy.build diff in
  let semantic =
    Semantic_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        files =
          [
            {
              path = "src/old_name.rs";
              language = "rust";
              symbols =
                [
                  {
                    id = "renamed_symbol";
                    kind = Function;
                    language_kind = Some "function";
                    name = "renamed_symbol";
                    span = { start_line = 1; end_line = 4 };
                    parent_symbol_id = None;
                    semantic = empty_semantic_properties;
                  };
                ];
            };
          ];
      }
  in
  let document =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  let symbol = semantic_symbol_node_by_source_id "renamed_symbol" document in
  Alcotest.(check string) "renamed symbol current path" "src/new_name.rs"
    symbol.path;
  Alcotest.(check string) "renamed symbol old path" "src/old_name.rs"
    (Option.value symbol.old_path ~default:"");
  Alcotest.(check string) "renamed symbol status" "renamed"
    (symbol.status
    |> Option.map Diff_types.diff_file_status_to_string
    |> Option.value ~default:"");
  Alcotest.(check int) "renamed additions" 1 symbol.diff.lines_added;
  Alcotest.(check int) "renamed deletions" 1 symbol.diff.lines_removed

let test_semantic_join_deleted_file_symbols () =
  let diff =
    Diff_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        comparison = { base = "base"; target = "target" };
        path_filter = None;
        files =
          [
            {
              path = "src/deleted.rs";
              old_path = None;
              status = Deleted;
              additions = 0;
              deletions = 6;
              is_binary = false;
              hunks =
                [
                  {
                    old_range = { start_line = 1; line_count = 6 };
                    new_range = { start_line = 0; line_count = 0 };
                    header = "@@ -1,6 +0,0 @@";
                    lines = None;
                  };
                ];
            };
          ];
        summary = { changed_files = 1; total_additions = 0; total_deletions = 6 };
      }
  in
  let hierarchy = Hierarchy.build diff in
  let semantic =
    Semantic_types.
      {
        version = 1;
        repo_root = "/tmp/repo";
        files =
          [
            {
              path = "src/deleted.rs";
              language = "rust";
              symbols =
                [
                  {
                    id = "deleted_symbol";
                    kind = Function;
                    language_kind = Some "function";
                    name = "deleted_symbol";
                    span = { start_line = 2; end_line = 4 };
                    parent_symbol_id = None;
                    semantic = empty_semantic_properties;
                  };
                ];
            };
          ];
      }
  in
  let document =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  let symbol = semantic_symbol_node_by_source_id "deleted_symbol" document in
  Alcotest.(check string) "deleted symbol status" "deleted"
    (symbol.status
    |> Option.map Diff_types.diff_file_status_to_string
    |> Option.value ~default:"");
  Alcotest.(check int) "deleted additions" 0 symbol.diff.lines_added;
  Alcotest.(check int) "deleted removals" 3 symbol.diff.lines_removed;
  Alcotest.(check (float 0.0001)) "deleted changed ratio" 1.0
    symbol.diff.changed_ratio

let test_scene_from_fixture () =
  let diff = read_diff_fixture () in
  let hierarchy = Hierarchy.build diff in
  let semantic = read_semantic_fixture () in
  let semantic_hierarchy =
    Semantic_join.build ~diff_document:diff ~hierarchy_document:hierarchy
      ~semantic_document:semantic
  in
  let scene = Scene.build semantic_hierarchy in
  let issue_markers =
    List.filter
      (fun (node : Scene_types.scene_node) ->
        node.Scene_types.kind = Scene_types.Scene_issue_marker)
      scene.scene.nodes
  in
  Alcotest.(check bool) "has issue markers" true (List.length issue_markers > 0)

let test_parse_raw_git_outputs () =
  let raw =
    Git_diff.
      {
        name_status = "M\tsrc/lib.rs\nA\tsrc/new.rs\n";
        numstat = "2\t1\tsrc/lib.rs\n3\t0\tsrc/new.rs\n";
        unified_diff =
          String.concat "\n"
            [
              "diff --git a/src/lib.rs b/src/lib.rs";
              "--- a/src/lib.rs";
              "+++ b/src/lib.rs";
              "@@ -1,2 +1,3 @@";
              " fn old() {}";
              "-let x = 1;";
              "+let x = 2;";
              "+let y = 3;";
              "diff --git a/src/new.rs b/src/new.rs";
              "--- /dev/null";
              "+++ b/src/new.rs";
              "@@ -0,0 +1,3 @@";
              "+pub fn a() {}";
              "+pub fn b() {}";
              "+pub fn c() {}";
              "";
            ];
      }
  in
  let diff =
    Git_diff.parse_outputs ~repo_root:"/tmp/repo" ~base:"base" ~target:"target"
      ~path_filter:None raw
  in
  Alcotest.(check int) "parsed files" 2 (List.length diff.files);
  let lib =
    List.find (fun file -> String.equal file.Diff_types.path "src/lib.rs") diff.files
  in
  Alcotest.(check int) "lib hunks" 1 (List.length lib.hunks)

let run dir args =
  let old = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir old)
    (fun () ->
      Sys.chdir dir;
      let pid =
        Unix.create_process "git" (Array.of_list ("git" :: args)) Unix.stdin
          Unix.stdout Unix.stderr
      in
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED 0 -> ()
      | _, Unix.WEXITED code ->
          Alcotest.failf "git %s exited %d" (String.concat " " args) code
      | _, Unix.WSIGNALED signal ->
          Alcotest.failf "git %s signaled %d" (String.concat " " args) signal
      | _, Unix.WSTOPPED signal ->
          Alcotest.failf "git %s stopped %d" (String.concat " " args) signal)

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let normalized_json_string json = Yojson.Safe.pretty_to_string json

let semantic_document_json_for_snapshot
    (document : Semantic_types.semantic_input_document) =
  let document =
    { document with Semantic_types.repo_root = "test/fixtures" }
  in
  Json_codec.semantic_input_document_to_yojson document

let test_extract_git_diff_smoke () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      ("gvd-test-" ^ string_of_int (Unix.getpid ()))
  in
  Unix.mkdir dir 0o700;
  run dir [ "init" ];
  run dir [ "config"; "user.email"; "test@example.invalid" ];
  run dir [ "config"; "user.name"; "Git Visualization Diff Test" ];
  write_file (Filename.concat dir "lib.rs") "pub fn value() -> i32 {\n  1\n}\n";
  run dir [ "add"; "lib.rs" ];
  run dir [ "commit"; "-m"; "base" ];
  write_file (Filename.concat dir "lib.rs") "pub fn value() -> i32 {\n  2\n}\n";
  write_file (Filename.concat dir "new.rs") "pub fn new_value() -> i32 {\n  3\n}\n";
  run dir [ "add"; "lib.rs"; "new.rs" ];
  run dir [ "commit"; "-m"; "target" ];
  match Git_diff.extract ~repo_root:dir ~base:"HEAD~1" ~target:"HEAD" ~path_filter:None with
  | Error message -> Alcotest.fail message
  | Ok diff ->
      Alcotest.(check int) "changed files" 2 diff.summary.changed_files;
      Alcotest.(check bool) "has lib.rs" true
        (List.exists (fun file -> String.equal file.Diff_types.path "lib.rs") diff.files)

let test_build_timeline_smoke () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      ("gvd-timeline-test-" ^ string_of_int (Unix.getpid ()))
  in
  Unix.mkdir dir 0o700;
  run dir [ "init" ];
  run dir [ "config"; "user.email"; "test@example.invalid" ];
  run dir [ "config"; "user.name"; "Git Visualization Diff Test" ];
  write_file (Filename.concat dir "lib.rs") "pub fn value() -> i32 {\n  1\n}\n";
  run dir [ "add"; "lib.rs" ];
  run dir [ "commit"; "-m"; "base" ];
  write_file (Filename.concat dir "lib.rs") "pub fn value() -> i32 {\n  2\n}\n";
  run dir [ "add"; "lib.rs" ];
  run dir [ "commit"; "-m"; "middle" ];
  write_file (Filename.concat dir "lib.rs") "pub fn value() -> i32 {\n  3\n}\n";
  run dir [ "add"; "lib.rs" ];
  run dir [ "commit"; "-m"; "target" ];
  match Timeline.build ~repo_root:dir ~base:"HEAD~2" ~target:"HEAD" ~path_filter:None with
  | Error message -> Alcotest.fail message
  | Ok timeline ->
      Alcotest.(check int) "timeline steps" 2
        (List.length timeline.Scene_types.steps);
      let first = List.hd timeline.steps in
      Alcotest.(check int) "first step index" 0 first.index;
      Alcotest.(check int) "first step changed files" 1
        first.document.metrics.changed_files

let test_language_detection () =
  Alcotest.(check string) "rust" "rust" (Language.detect_by_path "src/lib.rs");
  Alcotest.(check string) "cpp" "cpp" (Language.detect_by_path "src/widget.cpp");
  Alcotest.(check string) "c" "c" (Language.detect_by_path "src/widget.c");
  Alcotest.(check string) "swift" "swift"
    (Language.detect_by_path "Sources/App.swift")

let test_parser_registry_dispatch () =
  let check_file expected_language expected_symbol_count path source =
    match Parser_registry.extract_file ~repo_root:"/repo" ~path ~source with
    | Error message -> Alcotest.fail message
    | Ok None -> Alcotest.failf "expected extractor for %s" path
    | Ok (Some analysis) ->
        Alcotest.(check string) "language" expected_language
          analysis.Semantic_types.language;
        Alcotest.(check int) "symbol count" expected_symbol_count
          (List.length analysis.symbols)
  in
  check_file "rust" 1 "src/lib.rs" "pub fn main() {}\n";
  check_file "cpp" 1 "src/widget.cpp" "class Widget {};\n";
  check_file "swift" 1 "Sources/App.swift" "struct Widget {}\n"

let symbol_by_language_kind language_kind symbols =
  List.find
    (fun (symbol : Semantic_types.semantic_symbol) ->
      symbol.language_kind = Some language_kind)
    symbols

let symbol_by_language_kind_and_name language_kind name symbols =
  List.find
    (fun (symbol : Semantic_types.semantic_symbol) ->
      symbol.language_kind = Some language_kind && String.equal symbol.name name)
    symbols

let test_rust_symbol_extraction () =
  let path = test_fixture_path "sample.rs" in
  let source =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  match Rust_symbols.extract ~repo_root:(Filename.dirname path) ~path:"sample.rs" ~source with
  | Error message -> Alcotest.fail message
  | Ok symbols ->
      Alcotest.(check bool) "has several symbols" true (List.length symbols >= 7);
      let struct_symbol = symbol_by_language_kind_and_name "struct" "Widget" symbols in
      Alcotest.(check string) "struct name" "Widget" struct_symbol.name;
      let enum_symbol = symbol_by_language_kind "enum" symbols in
      Alcotest.(check string) "enum name" "Mode" enum_symbol.name;
      let impl_symbol = symbol_by_language_kind "impl" symbols in
      Alcotest.(check string) "impl name" "impl Widget" impl_symbol.name;
      let method_symbol =
        List.find
          (fun (symbol : Semantic_types.semantic_symbol) ->
            symbol.name = "new" && symbol.parent_symbol_id = Some impl_symbol.id)
          symbols
      in
      Alcotest.(check string) "method kind" "function"
        (Semantic_types.semantic_symbol_kind_to_string method_symbol.kind);
      let test_function = symbol_by_language_kind "test_function" symbols in
      Alcotest.(check string) "test fn name" "builds_widget" test_function.name;
      Alcotest.(check (list string)) "test pattern" [ "test" ]
        test_function.semantic.patterns;
      let generic_symbol = symbol_by_language_kind_and_name "struct" "Store" symbols in
      Alcotest.(check (list string)) "rust generic pattern" [ "generic" ]
        generic_symbol.semantic.patterns;
      Alcotest.(check bool) "test span has body" true
        (test_function.span.end_line > test_function.span.start_line)

let test_cpp_symbol_extraction () =
  let path = test_fixture_path "sample.cpp" in
  let source =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  match Cpp_symbols.extract ~repo_root:(Filename.dirname path) ~path:"sample.cpp" ~source with
  | Error message -> Alcotest.fail message
  | Ok symbols ->
      Alcotest.(check bool) "has cpp symbols" true (List.length symbols >= 5);
      let namespace_symbol = symbol_by_language_kind "namespace" symbols in
      Alcotest.(check string) "namespace name" "demo" namespace_symbol.name;
      let class_symbol = symbol_by_language_kind "class" symbols in
      Alcotest.(check string) "class name" "Widget" class_symbol.name;
      let template_class = symbol_by_language_kind_and_name "class" "Box" symbols in
      Alcotest.(check (list string)) "template class patterns"
        [ "template"; "generic" ] template_class.semantic.patterns;
      Alcotest.(check int) "template class starts at template line" 15
        template_class.span.start_line;
      let enum_symbol = symbol_by_language_kind "enum" symbols in
      Alcotest.(check string) "enum name" "Mode" enum_symbol.name;
      let method_symbol = symbol_by_language_kind_and_name "method" "value" symbols in
      Alcotest.(check string) "method name" "value" method_symbol.name;
      Alcotest.(check string) "method parent" class_symbol.id
        (Option.value method_symbol.parent_symbol_id ~default:"");
      let template_function =
        symbol_by_language_kind_and_name "function" "identity" symbols
      in
      Alcotest.(check (list string)) "template function patterns"
        [ "template"; "generic" ] template_function.semantic.patterns;
      let function_symbol =
        List.find
          (fun (symbol : Semantic_types.semantic_symbol) ->
            symbol.language_kind = Some "function" && symbol.name = "build_widget")
          symbols
      in
      Alcotest.(check string) "function name" "build_widget" function_symbol.name

let test_swift_symbol_extraction () =
  let path = test_fixture_path "Sample.swift" in
  let source =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> really_input_string channel (in_channel_length channel))
  in
  match Swift_symbols.extract ~repo_root:(Filename.dirname path) ~path:"Sample.swift" ~source with
  | Error message -> Alcotest.fail message
  | Ok symbols ->
      Alcotest.(check bool) "has swift symbols" true (List.length symbols >= 8);
      let protocol_symbol = symbol_by_language_kind "protocol" symbols in
      Alcotest.(check string) "protocol name" "Displayable" protocol_symbol.name;
      let enum_symbol = symbol_by_language_kind "enum" symbols in
      Alcotest.(check string) "enum name" "Mode" enum_symbol.name;
      let generic_symbol = symbol_by_language_kind_and_name "struct" "Store" symbols in
      Alcotest.(check (list string)) "swift generic pattern" [ "generic" ]
        generic_symbol.semantic.patterns;
      let struct_symbol = symbol_by_language_kind_and_name "struct" "Widget" symbols in
      Alcotest.(check string) "struct name" "Widget" struct_symbol.name;
      let class_symbol = symbol_by_language_kind "class" symbols in
      Alcotest.(check string) "class name" "Controller" class_symbol.name;
      let init_symbol = symbol_by_language_kind "initializer" symbols in
      Alcotest.(check string) "initializer parent" struct_symbol.id
        (Option.value init_symbol.parent_symbol_id ~default:"");
      let property =
        List.find
          (fun (symbol : Semantic_types.semantic_symbol) ->
            symbol.language_kind = Some "property"
            && symbol.parent_symbol_id = Some struct_symbol.id)
          symbols
      in
      Alcotest.(check string) "property parent" struct_symbol.id
        (Option.value property.parent_symbol_id ~default:"");
      let method_symbol =
        List.find
          (fun (symbol : Semantic_types.semantic_symbol) ->
            symbol.language_kind = Some "method" && symbol.name = "display")
          symbols
      in
      Alcotest.(check string) "method parent" struct_symbol.id
        (Option.value method_symbol.parent_symbol_id ~default:"")

let test_semantic_extract_with_adapter_symbols () =
  let rust = test_fixture_path "sample.rs" in
  let cpp = test_fixture_path "sample.cpp" in
  let swift = test_fixture_path "Sample.swift" in
  let repo_root = Filename.dirname rust in
  match
    Semantic_extract.extract ~repo_root
      ~files:[ Filename.basename rust; Filename.basename cpp; Filename.basename swift ]
  with
  | Error message -> Alcotest.fail message
  | Ok document ->
      Alcotest.(check int) "recognized semantic files" 3
        (List.length document.Semantic_types.files);
      let languages =
        document.Semantic_types.files
        |> List.map (fun (file : Semantic_types.semantic_file_analysis) ->
               file.Semantic_types.language)
        |> List.sort String.compare
      in
      Alcotest.(check (list string)) "languages" [ "cpp"; "rust"; "swift" ]
        languages;
      let rust_file =
        List.find
          (fun (file : Semantic_types.semantic_file_analysis) ->
            file.language = "rust")
          document.files
      in
      Alcotest.(check bool) "rust has symbols" true
        (List.length rust_file.symbols > 0);
      let cpp_file =
        List.find
          (fun (file : Semantic_types.semantic_file_analysis) ->
            file.language = "cpp")
          document.files
      in
      Alcotest.(check bool) "cpp has symbols" true
        (List.length cpp_file.symbols > 0);
      let swift_file =
        List.find
          (fun (file : Semantic_types.semantic_file_analysis) ->
            file.language = "swift")
          document.files
      in
      Alcotest.(check bool) "swift has symbols" true
        (List.length swift_file.symbols > 0)

let test_semantic_extract_golden_snapshot () =
  let rust = test_fixture_path "sample.rs" in
  let cpp = test_fixture_path "sample.cpp" in
  let swift = test_fixture_path "Sample.swift" in
  let repo_root = Filename.dirname rust in
  match
    ( Semantic_extract.extract ~repo_root
        ~files:[ Filename.basename rust; Filename.basename cpp; Filename.basename swift ],
      Json_codec.read_json_file (snapshot_path "semantic-extraction.json") )
  with
  | Error message, _ | _, Error message -> Alcotest.fail message
  | Ok document, Ok expected_json ->
      let actual_json = semantic_document_json_for_snapshot document in
      Alcotest.(check string) "semantic extraction snapshot"
        (normalized_json_string expected_json)
        (normalized_json_string actual_json)

let () =
  Alcotest.run "git_visualization_diff"
    [
      ( "fixtures",
        [
          Alcotest.test_case "diff fixture round trip" `Quick
            test_diff_fixture_round_trip;
          Alcotest.test_case "hierarchy from fixture" `Quick
            test_hierarchy_from_fixture;
          Alcotest.test_case "semantic join from fixture" `Quick
            test_semantic_join_from_fixture;
          Alcotest.test_case "semantic join precise hunk overlap" `Quick
            test_semantic_join_precise_hunk_overlap;
          Alcotest.test_case "semantic join deletion-only projection" `Quick
            test_semantic_join_deletion_only_projection;
          Alcotest.test_case "semantic join renamed old path symbols" `Quick
            test_semantic_join_renamed_file_old_path_symbols;
          Alcotest.test_case "semantic join deleted file symbols" `Quick
            test_semantic_join_deleted_file_symbols;
          Alcotest.test_case "scene from fixture" `Quick test_scene_from_fixture;
        ] );
      ( "git_diff",
        [
          Alcotest.test_case "parse raw outputs" `Quick test_parse_raw_git_outputs;
          Alcotest.test_case "extract from temporary repo" `Quick
            test_extract_git_diff_smoke;
          Alcotest.test_case "build timeline from temporary repo" `Quick
            test_build_timeline_smoke;
        ] );
      ( "adapters",
        [
          Alcotest.test_case "language detection" `Quick test_language_detection;
          Alcotest.test_case "parser registry dispatch" `Quick
            test_parser_registry_dispatch;
          Alcotest.test_case "rust symbol extraction" `Quick
            test_rust_symbol_extraction;
          Alcotest.test_case "cpp symbol extraction" `Quick
            test_cpp_symbol_extraction;
          Alcotest.test_case "swift symbol extraction" `Quick
            test_swift_symbol_extraction;
          Alcotest.test_case "semantic extract with adapter symbols" `Quick
            test_semantic_extract_with_adapter_symbols;
          Alcotest.test_case "semantic extract golden snapshot" `Quick
            test_semantic_extract_golden_snapshot;
        ] );
    ]
