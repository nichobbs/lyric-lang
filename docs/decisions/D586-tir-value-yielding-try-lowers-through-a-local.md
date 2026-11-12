# D586 - A `try` that ends a block yields its value through a local (docs/70 phase 3a, #8613)

**Status:** shipped; extends D575 (temporaries) and D583.

## Context

`try { ...; 42 } finally { ... }` as the last statement of a function body (or any non-Unit block) is the value of the block: the body's tail, or the tail of the catch that ran. `try` is a statement in TIR (`TsTry`), so the builder had no way to carry that value and counted the block as `a branch conversion` from `Unit` (the wide census after D583 still held such sites in the compiler, ecosystem and self-test areas).

## Decision

- No new TIR expression kind. The builder lowers the value through a local, as D575 does for reordered arguments: before the `TsTry` it declares a `var` of the block's type (`TsVar` with no initialiser), the body and each catch assign their tail value to it, and the block's value is that local.
- A body or catch whose tail never completes (a `panic`, a `return`) assigns nothing and stays a statement; a block that yields no value and does not leave is counted as `a try block that yields no value`.
- The finally block stays a Unit statement block.
- A function body that ends in a `try` is built with the declared return type as its type, so the `try` knows what it yields; other function bodies are built as before.

## Measured

`tir_build` 157 passes; a new case builds and verifies a `try`/`finally`, a `try`/`catch` and a body that panics. The wide census was not re-measured for this change alone.
