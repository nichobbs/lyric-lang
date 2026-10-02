# wasm32 `module` shape: `@wasmImport` host imports (docs/35 W3, slice 3)

Third slice of phase W3 (D-progress-1031). An `extern func` marked
`@wasmImport("module")` compiles to a wasm import the host satisfies through
`instantiate(..., { imports })`.

## What ships

- `CodegenUnit.wasmImports` and `WasmImportDecl`: the bridge collects the
  annotation per extern; codegen declares the function under a namespaced LLVM
  name with `wasm-import-module` / `wasm-import-name` attributes.
- `Lyric.WasmGlue`: `collectWasmImportsOf` validates signatures (`N0014`), the
  glue gets a `LYRIC_IMPORTS` table, and the `.d.ts` a typed `LyricHostImports`.
- Glue runtime: wrappers that decode arguments and encode results, a
  `missing host imports` error at instantiate, and `_initialize` moved after the
  codecs.
- `N0015` when `@wasmImport` is used without `--shape module`.

## Tests

`llvm_wasm32_module_self_test.l` (14 cases) gains: Int, String, Long, Bool and
Unit host imports across two modules (including an import named `log`, which
collides with libm without namespacing), the missing-import error, the typed
`.d.ts`, and `N0015`.
