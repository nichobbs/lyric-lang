# D570 - `buildPackage`: a checked file as a whole TIR package (docs/70 phase 3a, #8613)

**Status:** shipped; extends D338, D360 and D367.

## Context

The only whole-package assembler was `buildCensus`, a census that also returned its package as a side
product. The native backend's move onto TIR (docs/70 phase 4a) needs the package itself: every built body as
a `TFnDecl` keyed by its symbol, the bodies that did not build by name so it can fall back per function,
a name for every symbol (to mangle), and the order of a union's cases (their tags).

## Decision

`Lyric.Tir.Build.buildPackage(ctx, tbl, file, name): PackageBuild` (new file `build_pkg.l`) holds the loop
that `buildCensus` had, which is now a thin caller of it. `PackageBuild` carries
`pkg` (`TPackage`: `funcs` one `TFnDecl` per built top-level function, keyed by `TFnDecl.sym`; `symbols` the
entries the bodies reach and every type entry of the table), `failed` (a `FnBuildFailure` per body that did not
build: name, the checker's symbol when it has one, the I0002 messages), `total` and `built`,
`names` (a symbol's `id` to the key of the DefPath it was interned from, `symTableDefPathKeyOf`, for every symbol
in `pkg` and every case), `cases` (a union's or enum's `id` to its case symbols in declaration order, a case's
tag being its index) and the `uncovered`/`sites` counts the census reports. Scope today is top-level functions;
methods, impl members and protected entries join `pkg.funcs` in later slices without changing the record.

## Measured

`tir_build_self_test.l` builds a union and a function over it through `buildPackage`: one declaration keyed by
its symbol, no failure, a DefPath key for the function, and the union's three cases in declaration order named
`Circle` first and `Dot` last. The census output is unchanged (it still goes through `buildCensus`).
