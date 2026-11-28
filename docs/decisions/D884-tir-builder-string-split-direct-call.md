# D884 - The TIR builder builds `String.split` as a call of `Std.String.split`

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §6.3; found by the native-via-TIR census, phase 4a)

## Decision

1. **`s.split(sep)` is `XCall(Direct(Std.String::split), [s, sep])` when `Std.String.split` is visible** in the package's symbol table (the package imports `Std.String`). The checker records the member as the built-in `String.split`; the builder, which met it as `IoBuiltin("String.split")`, now names the plain Lyric function the standard library declares, as the AST pipeline calls it. The callee's declaration is registered with its signature (`(String, String) -> slice[String]`, `in` parameters) like any callee the body reaches.
2. **Without `Std.String` in scope the built-in stays**, so a bundle that does not contain the function never names it (the verifier and the bundle resolve every `Direct` callee).
3. The node's type must be `slice[String]`; any other typing keeps the built-in.

## Why

A TIR backend lowers a `Direct` call from the bundled function; it has no lowering for a `String.split` built-in, and it cannot call the function from a built-in's name. The native census reported `builtin String.split with 2 arguments` for every function using it, keeping those on the AST path that phase 4a deletes.

## Effect

`parts` in the census repro (`s.split(",")`) lowers from TIR on native and prints what the AST path prints. `tir_build_self_test.l` covers both forms (direct call with the import, built-in without). `format1`-`format4`, `array.toSlice` and `T.default()` at a record or `String` remain separate census items.
