# D-progress-948 — Record `.copy(field = value)`

**Status:** shipped

## Problem

The language reference (§2.4) defines `r.copy(field = value, ...)` as a
non-destructive update of a record value, but the self-hosted compiler never
implemented it: every call failed with T0113. Code that wanted it wrote the
full constructor out by hand, repeating every unchanged field.

## Decision

- **Type checking.** A `.copy(...)` call on a record receiver, where the
  record declares no `copy` method of its own, is checked against the
  record's fields at the receiver's instantiation. Every argument must be
  named (T0127), name a real field (T0101) at most once (T0127), and be
  assignable to that field exactly as a constructor argument would be
  (T0104). The call has the receiver's type. A user-declared `copy` method
  still takes precedence.
- **Lowering.** `Lyric.Mono.desugarRecordCopiesFile` runs straight after the
  type checker, on exactly the file the checker saw, and rewrites each
  validated call into
  `{ val t = recv; val t_b = eb; val t_a = ea; R(a = t_a, b = t_b, c = t.c) }`.
  The receiver and every argument are evaluated once, left to right, as
  written. An imported record's constructor is named by its declaring
  package's full path.
- **Why a separate pass.** The type checker records each validated site
  keyed by its source span, and a span carries no file identity. Straight
  after type checking, those spans are offsets into one checked text, so
  each key identifies one call. Later, a specialised copy of an imported
  generic brings spans from another package's text, which could collide with
  this file's. Desugaring before anything else runs avoids that, and the
  desugared file is also what contract metadata takes generic bodies from
  (`MiddleEndOptions.checkedSourceOut`), so a generic exported to another
  package carries a constructor call rather than a `.copy` its consumer
  could not lower. Two different sites sharing one key (only possible in
  synthesized, span-less code) are reported as M0005 rather than guessed.
- **Generic bodies from other packages.** Within one build (a sibling
  project package, or the stdlib), a generic's body reaches its consumer
  from source rather than from contract metadata, so its `.copy` has no
  site there. `Lyric.Mono` lowers such a call from the receiver's type as
  inferred in the specialised body, which names a record it knows (the
  declaring package's type checker has already validated the call). When
  that type cannot be inferred, it reports M0006 and asks for an explicit
  record type on the receiver, rather than leaving an unresolvable method
  call for the backend.

## Verification

`record_copy_self_test.l` (both targets) covers replacing one or several
fields, a no-argument shallow copy, a generic record, copy in return and
argument position, single left-to-right evaluation, and chained copies.
`typechecker_self_test.l` covers the diagnostics. The cross-package repro
covers `.copy` inside an exported generic body and on an imported generic
record.
