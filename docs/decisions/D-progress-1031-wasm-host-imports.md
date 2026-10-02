# D-progress-1031 — Host imports: `@wasmImport` extern funcs for the wasm32 `module` shape

**Status:** shipped (W3 slice 3)

Extends D-progress-1029; provides the "thin import into the TS runtime" that
`docs/65` §13.1 (U7, the client WASM host) applies view patches through, and the
mechanism the `[npm]` shims of `docs/35` §9 (W5) will lower to in the module
shape.

## Context

The module shape could call the host only through the WASI shim. A Lyric program
had no way to call a function the page supplies (the DOM, a patch applier,
logging), which `docs/35` §4 lists as the module shape's interface.

## Decision

1. **Syntax.** An `extern func` marked `@wasmImport("module")` is a host import;
   the string after `=` is the import name. The annotation reuses the extern
   syntax rather than adding a keyword, and is orthogonal to `@library`.
2. **Lowering.** The declaration carries LLVM's `wasm-import-module` and
   `wasm-import-name` attributes, so wasm-ld emits a real wasm import with no
   link flags. The LLVM symbol is namespaced (`wasmimport.<module>.<name>`) so
   an import named like a C function (`log`) cannot be resolved against libm.
3. **Types.** `Int`, `Long`, `Bool`, `Byte`, `Float`, `Double`, `String` and
   `Unit`, the same kinds as exports (`N0014` otherwise). A String parameter is
   borrowed and decoded by the glue; a String result is created fresh for the
   Lyric caller, which owns it (rule 6 of native/plan/04-arc-design.md).
4. **Glue.** `instantiate(source, { imports: { module: { name: fn } } })` takes
   functions over decoded values; the generated wrappers lower and lift around
   them. A declared import the host does not supply fails instantiation with a
   `missing host imports` error naming each one. Names not declared with
   `@wasmImport` still pass through as raw wasm imports. The `.d.ts` exports a
   `LyricHostImports` interface and makes `options` required when any import is
   declared.
5. **Scope.** `@wasmImport` needs `--shape module` (`N0015`); the import list is
   collected from the program's own packages. Synchronous calls only: an
   operation that completes later (`fetch`) needs a host completion hook into
   the scheduler, which a later slice adds.

## Consequences

- A Lyric client can push view patches to the page, log, read a host clock or
  call any page function without a new runtime seam per feature.
- `_initialize` now runs after the glue's codecs are defined, so a host import
  may be called during initialisation.
