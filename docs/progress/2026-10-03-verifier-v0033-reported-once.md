# `lyric prove` reports an untranslatable construct once (#7874)

`V0033` (#7848) fails a proof closed when a construct has no faithful
translation, such as a `UInt` operand beside an `Int` variable. VC
generation reported it at the expression, kept the ill-sorted term, and the
driver then failed to reconcile the goal it reached and reported `V0033`
again at the goal's origin: two errors for one cause. A construct in a
callee's `requires:`/`ensures:` was the opposite case: the call-site
translation discarded its diagnostics, so a goal could fail with no
`V0033` naming the construct when the callee itself was not proved. And an
untranslatable result range dropped its obligation from the postcondition,
so `--explain`/`--json` could list that goal as discharged although it was
weaker than the declared contract.

## Fix

- Where VC generation reports `V0033` it wraps the offending term in the
  marker application `lyric!untranslatable` (`poisonTerm`). The driver
  checks each goal for the marker (`goalIsPoisoned`) before sort
  reconciliation: such a goal's outcome is `unknown` ("not translatable: a
  construct reported above (V0033)") with no second diagnostic, and it never
  reaches the trivial discharger or the solver. A goal whose mix only
  appears after substitution is still reported once, at the goal.
- An untranslatable result range adds a poisoned `false` to the
  postcondition instead of nothing, so that goal is never discharged.
- `V0033` diagnostics from a callee's contract or `@pure` body, translated
  at each call, are kept, and `goalsForFile` drops a diagnostic identical in
  code, span and message to an earlier one, so the construct is reported
  once however many calls translate it.

## Verification

`verifier_self_test.l` asserts exactly one `V0033` for a single
`UInt`-beside-`Int` mix with its goal failed and nothing discharged, one for
an untranslatable result range with the postcondition failed, and one for a
mix in a callee's `requires:` called twice. The existing `V0033` cases still
pass.
