# Generic invariant types are checked at the public boundary on TIR (docs/70 phase 3c, D519)

## What shipped

- `Lyric.Tir.Contracts` finds and calls the checker of a generic invariant type, instantiated at the value's type arguments (entry, `inout`/`out` exit and result checks; D519, amends D507). The AST path is unchanged: its inserted generic checker call is not specialised on `--target jvm` (D519 item 2).
- `tir_contracts_self_test.l`: a generic `Cell[T]` is checked at exit with the D507 messages, and a public generic function's parameter of another package's generic type is checked on entry with one type argument; both verify.
- docs/01 §6.2 states where generic types are and are not checked: not yet at run time on any target (native falls back to the AST path for functions mentioning a generic record instance, #9370).
