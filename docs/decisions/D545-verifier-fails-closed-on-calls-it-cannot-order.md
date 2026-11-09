# D545 — The verifier fails closed on method calls over values it has no heap for (#8110)

**Status:** shipped

**Context.** Stream S2 of the v1.0 checklist (docs/12) covers verifier
soundness: #8142 (match arm guards), #8354 (`sortEq` and type arguments),
#8157 (index bounds), #8141 (`Float`) and #8306 (sibling-file records). Each
was re-checked on `main` before any change, with the regression tests of its
fix and with probes: all five are already fixed and pinned in
`lyric-compiler/lyric/verifier_self_test.l` (guards and `name @ p` patterns in
`vcgen_match.l`, a datatype's type arguments in `sortEq`, the bounds
obligation and sequence model in `vcgen_expr.l`/`theory.l`, IEEE 754
`Float64` in `smt.l`/`solver.l`, the package's other files in the record
scope of `vcgen_file.l`). No code changed for them.

The probes found the part of #8110 (open) that was still unsound: a method the
file does not declare was an uninterpreted function of its receiver and
arguments, so after `xs.add(1)` a later `xs.count` was proved equal to an
earlier one, and `xs.removeLast() == xs.removeLast()` was proved.

**Decision.** `translateMethodCall` (`vcgen_callee.l`) applies the
congruent uninterpreted function only where the receiver and every argument
are immutable values (`valueDetermined`). Any other call is `V0033`, with a
poisoned result. No heap model is added (that is #8110's open question):
the call is rejected, not approximated. The method can be declared in the file
with a contract, or the code can call a `@pure` function.

Exceptions, both kept as before: a sibling method called on `self` (#8231),
and a call on the binding of an arm whose pattern is not modelled, where every
goal the match's value reaches already fails (V0027). The second leaves one
residual hole: such a binding that aliases an outer collection and is
mutated in the arm; it is recorded on #8110 with the rest of its open list.

**Still open on #8110** (fail-closed or model needed): mutation through an
`in` record parameter by a declared callee, and verification of record methods
(`RMFunc`).

**Consequences.** `examples/prove-type-check/stubbable.l` read the stub's
result through `s.next()`, a call that increments the stub's counter; it reads
the stub's `next_value` field now. The `#8109` tests that mutated a list
between two `@pure` calls now expect `V0033` rather than a refutation.
