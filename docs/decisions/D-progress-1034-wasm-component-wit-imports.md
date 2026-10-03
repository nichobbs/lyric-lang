# D-progress-1034 — Component shape: `@wasmImport` lowers to WIT imports

**Status:** shipped (W4 slice 3)

Extends D-progress-1031 (host imports in the module shape) and D-progress-1033.

## Decision

1. **Same syntax, both shapes.** An `extern func` marked `@wasmImport("module")`
   keeps its meaning: call a function the host supplies. In the module shape that
   is a wasm import the JS glue satisfies; in the component shape it is a function
   of a WIT interface named for the module.
2. **WIT.** Each distinct module becomes an interface (`lyric:<package>/<module>@<version>`)
   and the world imports it; the function name is the import name kebab-cased.
3. **Lowering in generated C.** The AST pass rewrites the extern's symbol to a
   generated C function `lyric_host_<module>_<name>` and drops the annotation, so
   the native backend sees an ordinary C extern. The C function calls the real core
   import with canonical flat arguments (a string is borrowed as pointer and length)
   and lifts the result (a string result comes back through a return area the host
   fills with `cabi_realloc`, then `lyric_cabi_string_lift` copies and frees it).
   No new backend code, and the symbol rewrite also avoids the libm collision D-progress-1031
   solved with namespacing.
4. **Types.** `Int`, `Long`, `Float`, `Double`, `String` and `Unit` (result only);
   `Bool`, `Byte`, records and the rest are an error naming the parameter, and more
   than 15 flat parameters is an error. A `@wasmImport` in a bundled dependency
   package stays `N0017`.

## Not in this slice

Records, options and lists across a host import, `Bool`/`Byte`, async imports, and
cross-package types.
