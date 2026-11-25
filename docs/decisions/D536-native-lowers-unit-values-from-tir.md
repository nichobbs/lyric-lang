# D536: the native TIR lowering handles Unit parameters, locals and arguments

Status: accepted (docs/70 phase 4a, part 7; D520 slice 36).

## Decision

1. **A Unit value owns no storage.** As on the AST path, a Unit parameter keeps its position in the signature (an `NVoid` parameter, printed as `i8`), and a call passes a placeholder argument (`i8 undef`) in that position. The argument expression is still evaluated for its effects.
2. **A Unit local** is declared as a marker slot (empty pointer, type `NVoid`) in `LCtx.slots`: a read yields Unit with no load, and a `val`/`var` initialiser is evaluated and discarded. Anything that needs an address (a capture, `nativeAddrOf`, an `out` argument) refuses a Unit slot and keeps the function on the AST path with a census reason.

## Not done

- Assignment to a Unit local: the lowering handles it (the right-hand side is evaluated), but the AST path cannot lower it ("no storage slot"), so the e2e comparison has no fixture for it.
- Unit pattern bindings and fields, and Unit lambda parameters, still fall back.

## Verification

`scripts/ci/native-via-tir/unit.l` (a Unit parameter, a Unit `val`, a Unit-valued argument) lowers 4 of 4 functions from TIR with the AST path's output and runs clean under AddressSanitizer (`native-via-tir-e2e.sh`).
