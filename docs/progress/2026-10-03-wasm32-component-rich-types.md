# wasm32 component shape, slice 2: rich types (docs/35 W4)

`--shape component` now carries `Option`/`T?`, `Result`, `List`, and the
program's own records, enums and one-payload unions, nested freely, in both
directions (D-progress-1033).

## What ships

- `Lyric.ComponentGlue` rewritten around a WIT type model: resolution from the
  package AST, canonical layout (flat slots with variant joins, memory size and
  alignment), WIT type definitions, and generated Lyric lift/load/store/free
  shims plus a small generated C primitive layer.
- The native bridge threads the per-package export plans from the AST pass to
  the link step; the old string-only C wrappers are gone.
- `llvm_wasm32_component_self_test.l`: a rich-type program exercised through
  `jco` and node (records, nested record/list/option, results with `Err`, lists
  of records, enums, variants, empty lists, 18-parameter spilled call).

## Remaining W4

Tuples, WIT imports, cross-package types, `--wit-out`/`--js-bindings`, publish
bundle, async exports, `[wasm]` table.
