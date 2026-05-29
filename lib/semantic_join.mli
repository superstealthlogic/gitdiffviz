open Diff_types
open Hierarchy_types
open Semantic_types

val from_repository_hierarchy :
  repository_hierarchy_document -> semantic_hierarchy_document

val build :
  diff_document:git_diff_document ->
  hierarchy_document:repository_hierarchy_document ->
  semantic_document:semantic_input_document ->
  semantic_hierarchy_document
