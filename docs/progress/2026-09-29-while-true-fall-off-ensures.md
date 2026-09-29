# `while true` is an unconditional loop for the fall-off `ensures:` check (#7759)

`stmtAlwaysExits` in `Lyric.ContractElaborator` classified only a `do { }`
loop with no `break` as never completing normally; every `while` and `for`
counted as "may complete". The language reference (§4) documents
`while true { ... if cond { break } }` as the idiomatic unconditional loop,
so a `Unit` function ending in `while true { ... return ... }` with no `break`
got a postcondition assert appended after the loop (#7747's fall-off check),
where nothing can reach it. The non-`Unit` trailing-value rewrite, which uses
the same classification through `blockAlwaysExits`, also wrapped a trailing
`if` whose branch ended in such a loop in a result binding plus an
unreachable assert. A `while true` with a loop `invariant:` further got the
normal-exit invariant check (#7224) appended after it, also unreachable.
Unreachable trailing code of this shape has caused backend
`InvalidProgramException`s before (#3505, #3842).

Fix: `stmtAlwaysExits` treats `while <cond>` whose condition is the literal
`true` (through any parentheses, `isLiteralTrue`) and whose body no `break`
leaves exactly like `do`. The break scan is the existing `loopHasBreak` /
`markBreaksBlock`: a bare `break` directly in the body, or `break <label>`
naming the loop from inside a nested loop, counts; a bare `break` in a nested
loop does not, and a nested loop re-using the label shadows it. The loop being
classified is always the function's trailing statement (possibly inside a
trailing `scope`/`try`/`if`/`match`), never inside another loop, so no
enclosing label can name a loop around it. `SWhile` elaboration no longer
emits the normal-exit invariant check for `while true`: its condition never
goes false, and exits through `break` carry no invariant obligation. `for`
needs no change: every `for` iterates a finite collection or bounded range
(the grammar has no unbounded `for` form).

Verified by five new cases in the dual-target
`contract_fall_off_ensures_self_test.l` (a `Unit` function ending in `while
true` left by `return`, by `break`, by a labelled `break` from an inner loop,
one with an `invariant:`, and an `Int` function whose trailing `if` branch ends
in `while true`), on `--target dotnet` and `--target jvm`, plus `ilverify` of
the dotnet test DLL, and six elaborator shape tests in
`contract_elaborator_self_test.l`.
