# D448 - A function used as a value is recorded by the declaration's own span (docs/70 phase 3a, #8613)

**Status:** shipped. A checker bookkeeping fix; what the checker accepts and the language are unchanged.

## Context

The builder counted "a name that is not a local" for a function passed by name (`mapExprsInFile(woven, lowerFormatBuiltin)`, `pipeline.l:6037`), but only in the full compiler build. Part 8's single-file, two-file, forward-reference and cross-package repros all built, because none of them gave the function a doc comment.

The trace (`LYRIC_DEBUG_FUNCREF`, a temporary hook in `recordFuncRefNode`, not kept) showed `symTableFuncDefPathKey` finding one candidate symbol and rejecting it: the symbol's `declSpan` was `240727:242848` and the signature's span `241574:242848`. The symbol is added with the item's span, which starts at the item's doc comment and annotations; the signature carries `fn.span`, the declaration's own, which starts at `func`. A call is rescued by the same-arity fallback (`allowArityMatch`); a function value passes `false`, so a documented function referenced as a value was never recorded and the builder had no `RefSite` for it.

## Decision

`symTableFuncDefPathKey` also matches the symbol's `FunctionDecl.span` against the signature's span (the way `symTableFuncSymOf` already does); the item span still matches, so extern-block members, whose two spans agree, are unchanged.

## Results

`tir-builder-shapes-e2e.sh` gains `documented_function_value` (a doc-commented function defined after the call that passes it by name; built with `--verify-ir` and run). The `Lyric.Pipeline` census no longer counts the two `lowerFormatBuiltin` sites (6037, 6109), and the shape builds and runs on dotnet and the JVM.
