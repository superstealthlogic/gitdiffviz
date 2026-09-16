open Semantic_types

let extractor_for_language = function
  | "rust" -> Some (module Rust_symbols : Symbol_extractor_intf.S)
  | "c" | "cpp" -> Some (module Cpp_symbols : Symbol_extractor_intf.S)
  | "swift" -> Some (module Swift_symbols : Symbol_extractor_intf.S)
  | "python" -> Some (module Python_symbols : Symbol_extractor_intf.S)
  | "typescript" | "javascript" ->
      Some (module Typescript_symbols : Symbol_extractor_intf.S)
  | _ -> None

let supports_path path =
  Language.detect_by_path path |> extractor_for_language |> Option.is_some

let extract_file ~repo_root ~path ~source =
  let language = Language.detect_by_path path in
  match extractor_for_language language with
  | None -> Ok None
  | Some extractor ->
      let module Extractor = (val extractor : Symbol_extractor_intf.S) in
      (* Report the language detected from the path rather than the adapter's
         canonical name: one adapter serves several languages (TypeScript and
         JavaScript, C and C++) and downstream file nodes are labelled by path. *)
      Result.map
        (fun symbols -> Some { path; language; symbols })
        (Extractor.extract ~repo_root ~path ~source)
