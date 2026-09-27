# D-progress-994 — `@proof_required` builds keep runtime contract checks

**Status:** shipped

Closes #7227.

## Problem

The contract elaborator skipped every `@proof_required` file: it lowered no
`requires:`, `ensures:` or `invariant:` clause into a runtime check, on the
basis that `lyric prove` discharges those obligations. But `lyric build`
and `lyric test` never run the verifier; only `lyric prove` does. A
`@proof_required` package that was built without being proved therefore
had no contract checking at all, and nothing warned about it.

## Decision

Of the two options #7227 lists, this takes (b): a build keeps the runtime
checks.

- `elaborateFileWithInterfaces` elaborates a `@proof_required` file exactly
  like a `@runtime_checked` one. Every clause becomes a runtime check,
  and `fn.contracts` still carries the source clauses that `lyric prove`
  reads.
- A quantifier conjunct has no runtime form, so it stays a proof-only
  obligation. The W0002 warning for it is still suppressed in
  `@proof_required` files, where the annotation already says the property
  is proved.
- `lyric prove` is unchanged and remains the command that enforces the
  static guarantee.

Option (a) was not taken. It would run the verifier during `lyric build`
and drop the checks it discharges, but the build has no per-clause mapping
from discharged goals back to runtime checks. Without that mapping, the
only way to elide checks is to elide all of them, which is the unsound
state this entry fixes. Build-time proving with per-obligation elision is
tracked in #7431.

## Consequences

`Std.Core.Proof` (`lyric-stdlib/std/core_proof.l`), the only
`@proof_required` stdlib file, now checks its eight `ensures:` clauses at
runtime. All of them are trivially true.

## Tests

`contract_elaborator_self_test.l`: "proof_required file keeps runtime
checks" replaces the test that pinned the old skip.

## Docs

- Language reference §2.3 (range subtypes) and the verification-levels
  list.
- Book chapters 2 and 8: a build keeps runtime checks, and `lyric prove`
  discharges obligations.
