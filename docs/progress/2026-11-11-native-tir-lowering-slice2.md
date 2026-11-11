# Native backend on TIR, slice 2: scalar match and range loops (docs/70 phase 4a, D520)

`Lyric.LlvmTir` now lowers `match` on scalar scrutinees (literal, range,
binding, wildcard and or patterns, guards) and `for` over integer ranges, and
fixes a `Bool` widening that sign-extended and unsigned literals above the
signed maximum. The emitted IR for a `match` and a `for` was assembled and run
with clang (results checked), which found a missing phi edge from the dead
block after the exhaustiveness panic; `llvm_tir_self_test.l` now asserts it.

Still on the AST path: strings, records and unions with ARC, tuples, lists,
closures, interfaces, protected entries, and everything that needs the
whole-package producer (`--via-tir` wiring and the census).
