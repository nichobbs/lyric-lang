# D357 - A distinct type's constructor call is typed (docs/70 phase 3a, step 4)

**Status:** shipped. A slice of the I0001 gate work (D341, D355).

## Context

`type Score = Int` makes `Score(42)` a value of the distinct type. The checker
had a rule for `Score.from(x)` and `Score.tryFrom(x)` and for `.value`, but none
for the constructor call itself: it fell through to the callee-as-function-value
path and the call became a `TyError` with no diagnostic, and so did every use of
the value after it. A census of `lyric test` over the compiler's self-tests with
the gate on (`LYRIC_TYERR_GATE=1`) found it as the largest class of silent sites
(`equality_self_test.l`, `derives_self_test.l`).

## Decision

`distinctCtorType` types a call of a non-generic distinct type's bare name as that
type, after the constructor, union-case and function rules and before the
union/enum type-name check (T0125). The one argument is checked against the
underlying type (T0043) and a call with another number of arguments is T0042. A
name the scope binds, and a generic distinct type (whose underlying type depends
on its arguments), keep the other rules.

## Not in this change

The census was partial (about 235 of 610 items; compiler self-tests under
`LYRIC_LOAD_COMPILER=1` take minutes each). The other classes it found are open
for the I0001 flip, which stays the opt-in warning W0036 until the census is
zero: tuple-pattern bindings of an open collection, `xs[0]` and `.toInt()` on an
extern host array or constant, an extern property read, an open receiver
(`emptyCell().orDefault(await five())`), `externAsObject(ts)`, `result.field` in
a proof example's `ensures`, and the JVM auto-FFI self-test.

## Tests

`typechecker_self_test.l`: a distinct constructor call is typed with no silent
site and no diagnostic, a wrongly typed argument is T0043, two arguments are
T0042.
