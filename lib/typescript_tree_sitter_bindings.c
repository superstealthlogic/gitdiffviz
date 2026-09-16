/*
  OCaml bridge for the vendored tree-sitter TypeScript grammars.

  tree-sitter-typescript ships two grammars from one grammar definition: the
  `typescript` dialect, which accepts `<T>expr` type assertions but no JSX, and
  the `tsx` dialect, which accepts JSX but reads `<T>` as a JSX tag. Both are
  exposed here so the OCaml side can pick a dialect per file extension.
*/

#include <string.h>
#include <tree_sitter/api.h>

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

// Implemented by the vendored tree-sitter-typescript parser.c files.
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);

typedef struct {
  TSParser *parser;
} parser_W;

static void finalize_parser(value v) {
  parser_W *p = (parser_W *)Data_custom_val(v);
  ts_parser_delete(p->parser);
}

static struct custom_operations parser_custom_ops = {
  .identifier = "tree-sitter-typescript parser",
  .finalize = finalize_parser,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

static value create_parser_for(const TSLanguage *language) {
  CAMLparam0();
  CAMLlocal1(v);

  parser_W parser_wrapper;
  TSParser *parser = ts_parser_new();
  parser_wrapper.parser = parser;

  v = caml_alloc_custom(&parser_custom_ops, sizeof(parser_W), 0, 1);
  memcpy(Data_custom_val(v), &parser_wrapper, sizeof(parser_W));
  ts_parser_set_language(parser, language);
  CAMLreturn(v);
}

CAMLprim value gvd_create_parser_typescript(value unit) {
  return create_parser_for(tree_sitter_typescript());
}

CAMLprim value gvd_create_parser_tsx(value unit) {
  return create_parser_for(tree_sitter_tsx());
}
