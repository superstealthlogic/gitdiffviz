/*
  OCaml bridge for the vendored tree-sitter Rust grammar.
*/

#include <string.h>
#include <tree_sitter/api.h>

#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

// Implemented by the vendored tree-sitter-rust parser.c.
TSLanguage *tree_sitter_rust(void);

typedef struct {
  TSParser *parser;
} parser_W;

static void finalize_parser(value v) {
  parser_W *p = (parser_W *)Data_custom_val(v);
  ts_parser_delete(p->parser);
}

static struct custom_operations parser_custom_ops = {
  .identifier = "tree-sitter-rust parser",
  .finalize = finalize_parser,
  .compare = custom_compare_default,
  .hash = custom_hash_default,
  .serialize = custom_serialize_default,
  .deserialize = custom_deserialize_default
};

CAMLprim value gvd_create_parser_rust(value unit) {
  CAMLparam0();
  CAMLlocal1(v);

  parser_W parser_wrapper;
  TSParser *parser = ts_parser_new();
  parser_wrapper.parser = parser;

  v = caml_alloc_custom(&parser_custom_ops, sizeof(parser_W), 0, 1);
  memcpy(Data_custom_val(v), &parser_wrapper, sizeof(parser_W));
  ts_parser_set_language(parser, tree_sitter_rust());
  CAMLreturn(v);
}
