# D489 - The array copy and the zero value of an array are TIR nodes (docs/70 phase 3a and 4a, #8613)

**Status:** shipped; requested by the native backend lowering from TIR (D520).

## Context

An array (`array[N, T]`, D167) has value semantics: an array read out of a place and then stored must not share storage with its source, and an array declared without an initializer is zero filled. The checker records both as AST side tables (`SymbolTable.arrayCopySites`, `arrayCopyExempt`, `arrayZeroSites`) that `lowerArrays` consumes. TIR carried neither, so a native function touching an array of references (a `List` there, with reference semantics unless copied) had to stay on the AST path.

## Decision

Two `TExprKind` cases, no change to any existing one:

- `XArrayCopy(inner)`: a copy of the array `inner`, of the same type. `buildExpr` wraps the node built for an expression whose span is in `arrayCopySites` when its type is an array; a site the checker removed (`exemptArrayCopy`: an index receiver, `.length`, `==`, an assignment target, an `inout` argument) is not in the table and is not wrapped.
- `XZeroValue(ty)`: the zero value of the array type `ty`, the initializer of a `var a: array[N, T]` written without one (`arrayZeroSites` at the statement's span). An element is zero as `zeroExprFor` defines it, so a record element is a record of zero fields, not an all-zero bit pattern.

`Lyric.Tir.Verify` checks that a copy has its operand's array type and a zero value has its own `ty` as the node type, which is an array (rules `array-copy`, `zero-value`). The interface codec records only the default kinds it lists and treats the rest as not carriable, so the format is unchanged; `iface_dump` prints both. `llvm_tir.l` refuses an unknown kind, so a backend adds its lowering when it is ready.

## Results

`tir-builder-shapes-e2e.sh` gains `array_copy_and_zero` (a zero filled `var`, a copy stored in a `var` and in a record field, built with `--verify-ir` with 0 I0003; exit 27, where a shared array would exit 36). `tir_verify_self_test.l` gains three cases.

Not covered yet (open): the zero value of a record field of array type with no default (`arrayZeroSites` by the field's span) and the zero arguments a construction leaves out (`arrayCtorZeroArgs`); the proven index (`arrayIndexSites`); `arrayLiteralSites` for a bracket literal typed as an array.
