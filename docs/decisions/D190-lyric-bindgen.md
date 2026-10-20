# D190 - `lyric bindgen`: native FFI bindings from a C header

**Status:** accepted, implemented (docs/67 phase G3, #7942); realises docs/67 §5.3 for the clang input

## Decision

1. **Command.** `lyric bindgen <header.h> --package <Name> --allow <file> [-o <out.l>] [--library <name>]`
   runs `clang -Xclang -ast-dump=json -fsyntax-only` and writes a `_kernel_native/`
   binding file. The generator is the pure function `Lyric.Bindgen.generateBindings`
   (AST JSON in, source and notes out); `cli_bindgen.l` only runs clang and does I/O.
2. **Selection by allow-list.** A header such as SDL3 or `webgpu.h` has hundreds of
   declarations. Patterns (exact or `prefix*`) choose functions, records and enum
   constants; structs reached from a chosen function are bound transitively.
3. **Faithful or skipped.** A symbol is bound only if every part has a native
   layout: 8/32/64-bit integers, `bool`, `float`, `double`, pointers, enums, structs
   of those, arrays. Others (16-bit integers, bit-fields, unions, variadics,
   function-pointer fields, ambiguous callbacks) are skipped with a note. Naming one
   exactly is an error, so a binding the author depends on cannot silently go missing.
4. **Callbacks.** A function-pointer parameter becomes a function type whose user
   pointer is `NativeUserdata` (D189): the callback's only `void *` parameter, or the
   one a `userdata <callback> <index>` line names (clang's AST carries no parameter
   names in function-pointer types, so a name heuristic is not available).
5. **Link requirement.** `--library` puts `@library("name")` on every extern, which is
   what makes a native build link that library (D158), including from a dependency.
6. **Checked in, checked in CI.** Output is deterministic and carries no machine
   paths. `--check` compares against `-o` and fails on a difference.
7. **Signedness.** Unsigned C types map to the signed Lyric type of the same width.
   The bits are identical; ordering and division of values above the signed range are
   the wrapper's concern.

## Not in this slice

The `webgpu.yml` input (docs/67 §5.3) is added with G5, where its structure
(chained structs, per-version nullability) can be designed against `lyric-gpu`.
