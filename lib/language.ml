let extension path =
  let name = Filename.basename path in
  match String.rindex_opt name '.' with
  | None -> ""
  | Some index -> String.sub name index (String.length name - index)

let detect_by_path path =
  match String.lowercase_ascii (extension path) with
  | ".rs" -> "rust"
  | ".ml" | ".mli" -> "ocaml"
  | ".cpp" | ".cc" | ".cxx" | ".hpp" | ".hh" -> "cpp"
  | ".c" | ".h" -> "c"
  | ".ts" | ".tsx" | ".mts" | ".cts" -> "typescript"
  | ".js" | ".jsx" | ".mjs" | ".cjs" -> "javascript"
  | ".swift" -> "swift"
  | ".py" | ".pyi" -> "python"
  | ".mojo" -> "mojo"
  | ".md" -> "markdown"
  | ".json" -> "json"
  | ".toml" -> "toml"
  | _ -> "unknown"
