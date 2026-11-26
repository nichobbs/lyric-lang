# Native TIR names the instances of overloaded generics as the AST path does (docs/70 phase 3c, #9431)

## What shipped

- The native TIR lowering names a generic's instance from its origin's package and name and its type arguments. Two generics of one name in a package (`gen[T](x, y = 1, z = 2)` and `gen[T](x, y = 1)`) got the same name, so a call bound to the wrong body (the arity-2 call ran the arity-3 definition). The instance name now carries the mark the AST path's `Lyric.Mono` gives the second and later declarations of such a set (`gen__o1__String`), so each overload has its own IR name (`tirOverloadMark` in `llvm_codegen.l`).
- `scripts/ci/native-via-tir/overloads.l` and a block in `native-via-tir-e2e.sh`: the same output as the AST path (100, 300, 7). `generic_overload_arity_self_test.l` passes with `LYRIC_NATIVE_VIA_TIR=1`.
