# D577 - A write to a field not declared `var` is V0015 through every receiver (#9008)

**Status:** shipped; supersedes the narrow coverage of V0015 recorded in docs/01 §2.4 (issue #1815 parts 1-2, #6203, #6181).

## Context

docs/01 §2.4 says only a `var` field is a place. V0015 enforced that for the shapes the mode checker resolves without a symbol
table (a `var` local of a same-file record, an `inout` parameter, `self` in a method) and documented the rest as untracked: a write
through a `val` or `let` binding, a field chain, an `in` parameter, a record of another file, a compound assignment on any of
them. Those programs compiled, while the typed IR verifier (docs/70 §6.4, `assign-mutable`, D323) rejected the same writes, which
is the "checker accepts, backend fails" class docs/70 exists to end. The wide TIR census (#8994) found one such program (a
self-test); #9008 recorded the gap and the owner approved closing it.

## Decision

The type checker rejects every write, plain or compound, to a field of a record that is not declared `var`, with V0015 and the
mode checker's message (`cannot reassign immutable field 'b.n'; declare it `var n` on record 'Inner' to allow mutation`):

- Both places an assignment is checked call `checkNonVarFieldWrite`: the statement form in `typechecker_stmts.l` and the expression
  form in `typechecker_exprs.l`. The receiver is typed again with its diagnostics discarded, and the field is looked up among the
  record's fields (`FieldEntry.isMutable`, new), so a receiver that is a `val`/`let` local, an `in` parameter, a field chain, `self`
  or a record of another package (restored ones too: their contract metadata keeps `var`) is judged the same way.
- Construction and `.copy(...)` are not writes. A protected type keeps its own rules (a bare `let` field written in a member is
  T0087; a protected value's fields are reached by bare name only inside it). A `ref record` handle's `var` fields may be written
  through an `in` handle, and a `var` field of a plain record through an `in` parameter stays V0038 (D303).
- The type checker runs first and the pipeline stops at its errors, so the mode checker's narrower V0015 pass is not reached for a
  program the new rule rejects; the pass and the whole-build write-safety audit for `initonly`/`ACC_FINAL` fields (#6596) are unchanged.

## Measured

Reject corpus (`testdata/reject/`, both targets): `field_write_val_local`, `field_write_compound`, `field_write_chain`,
`field_write_in_param`, `field_write_self_method`, `field_write_other_package`. `field_write_self_test.l` (3 cases, dotnet and JVM)
writes `var` fields through a `val` ref-record local, an `in` ref-record parameter, a ref-record field chain, a `var` local and an
`inout` parameter. Programs the new rule rejects, across the compiler and its standard-library closure, the standard-library tests,
the ecosystem libraries and the compiler's test programs: none (the sweep and CI's stage 2 compile all of them with the new rule).
The one program that violated it, `compound_string_assign_self_test.l`, was fixed in D576's PR.
