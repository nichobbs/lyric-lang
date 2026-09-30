# A local `val`'s pattern must match every value of its initializer (#7778)

A local `val` binds its pattern unconditionally: both backends destructure the
initializer with no failure path. The checker never compared the pattern with
the initializer's type — it bound the names with the untyped `bindPattern` —
so `val (a, b) = 5`, `val (a, b) = (1, 2, 3)`, a nested arity mismatch and
`val Some(x) = opt` all compiled. `val (a, b) = 5` then threw
`NullReferenceException` on dotnet and failed JVM verification (`VerifyError`).
#7763 added the module-level counterpart (T0144); docs/01 said nothing about
refutable local patterns, so they had no defined meaning.

Fix: `checkLocalValPattern` (`typechecker_stmts.l`) runs on every local `val`
whose pattern is not a plain name, against the annotation when there is one and
the initializer's type otherwise. `localValPatternProblem` walks the pattern
with the type: a tuple pattern needs a tuple of its arity, at every level; a
constructor pattern needs the sole case of a single-case union (its payload
patterns checked against the case's instantiated field types); a record
pattern's field patterns are held to the same rule; a literal, range,
type-test, alternative or const pattern can always fail. A type the checker
could not resolve (`TyError`, a type parameter, `Never`) rules out no shape. A
failing pattern is **T0146** at the pattern — a new code, since T0144's wording
and its stricter rule (no constructor or record patterns at all) are
module-level — and its names are bound as `TyError`, so nothing cascades from
the mismatch. The single-case constructor and record destructuring already
used in `async_sm_self_test.l` stay valid.

Verified by nine new `typechecker_self_test.l` cases (a tuple pattern over
`Int`, wrong arity, nested wrong arity, an annotated mismatch, no cascade, a
correct nested pattern typing its names, a constructor over a two-case union,
a literal inside a tuple pattern, and the accepted single-case constructor /
record / `@` / wildcard forms): 706/713 before, 713/713 after. Five new
dual-target cases in `tuple_pattern_binding_self_test.l` (wildcard element,
nested tuple annotation, parenthesised elements, a single-case union and a
record pattern) run 27/27 on `--target dotnet` and `--target jvm`. docs/01
§4.4, the grammar's `LocalBinding` note and the book's T0146 row describe the
rule.

Not changed here: a local `val name @ (a, b) = ...` passes the checker but
fails in codegen on both targets (the backends' local-binding lowering drops
the inner pattern of an `@` binding); it is tracked separately.
