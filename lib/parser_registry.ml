open Semantic_types

let extractor_for_language = function
  | "rust" -> Some (module Rust_symbols : Symbol_extractor_intf.S)
  | "c" | "cpp" -> Some (module Cpp_symbols : Symbol_extractor_intf.S)
  | "swift" -> Some (module Swift_symbols : Symbol_extractor_intf.S)
  | _ -> None

let extract_file ~repo_root ~path ~source =
  let language = Language.detect_by_path path in
  match extractor_for_language language with
  | None -> Ok None
  | Some extractor ->
      let module Extractor = (val extractor : Symbol_extractor_intf.S) in
      Result.map
        (fun symbols -> Some { path; language = Extractor.language; symbols })
        (Extractor.extract ~repo_root ~path ~source)
