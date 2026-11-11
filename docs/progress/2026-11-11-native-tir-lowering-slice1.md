# Native backend on TIR, slice 1: scalar functions (docs/70 phase 4a, D520)

`Lyric.LlvmTir` (`lyric-compiler/lyric/llvm_tir.l`) lowers a monomorphic
`TFnDecl` of scalar type to an LLVM `NFunc` from TIR alone: types from
`TExpr.ty`, callees from `Callee`, conversions from `ConvKind`, IR names from
the linkage table `TirLowerEnv.fnNames`. A function outside the slice returns a
`TirFallback` with its reason, so the AST path keeps lowering it and the
census can count it. `llvm_tir_self_test.l` builds TIR by hand and asserts on
the rendered IR and on the fallback reasons.

Not yet wired: the `--via-tir` flag and the census, which need the builder's
whole-package entry point (`TPackage`/`TFnDecl` assembly is in flight in
phase 3a). Next slices: strings, records and unions with ARC, `match`,
tuples, lists, closures, interfaces, protected entries.
