# 2026-09-28 — Bare pattern heads now get the T0097 privacy check too (#7591)

Fixes #7591, a gap raised in review of #7590 (D-progress-1015) that this
codebase's #7548 (D-progress-1012) and #7584 (D-progress-1015) pattern-head
fixes shared: the privacy check they added lived only inside the
"qualified" branch of each pattern-head validator, on the assumption that a
bare head is always safe because the scrutinee "could only have that type
by importing it."

That assumption doesn't hold: a `pub` function can return a value of a
package-private record, union, or enum with no diagnostic at its own call
site, and the caller never has to name the type at all. Matching that
call's result with a bare pattern head (`case Point { x = a, y = _ } ->`,
`case A(x) ->`, `case Active ->`) is then the first point the private type
or case actually gets named — and, before this fix, that head silently
resolved with no T0097.

## What #7535 (D141) already covered

D141's tiered bare-name lookup (`symTableTryFindOne`, `visibleBareSig`) and
its explicit carve-out — "a pattern names a case of the scrutinee's own
type whatever the imports" — govern whether a bare pattern head resolves
to a case *at all* (as opposed to a fresh binding), not whether that case
is *privacy-checked* once resolved. #7535 did not touch either pattern-head
privacy path this fix closes; the gap predates it and is orthogonal to it.
D141's carve-out is preserved exactly: this fix adds only the T0097
privacy check for the bare form, never a T0020 reachability check — a bare
head's package is reachable by construction once it isn't private, exactly
as D141 already established for name resolution.

## The three (really four) resolution paths

A pattern head resolves to a union/enum case or a record through three
separate type-checker code paths, all of which had the same
qualified-only gap:

- `unionCaseSymbolForScrutinee` (`typechecker_exprs.l`) — a `PConstructor`
  pattern head, e.g. `case A(x) -> …`. Covers both a payload-bearing case
  and a case written with explicit parens.
- `checkBareCasePatternScrutinee` — a bare *nullary* case head with no
  parens (`case Active -> …`, `case B -> …`). This parses as a `PBinding`
  (grammar has no separate "case reference" pattern kind) and is
  disambiguated to a case constructor by `bindPatternTyped`'s `PBinding`
  arm (`isConstructorPatternName`/`scrutineeHasCaseNamed`) entirely outside
  `unionCaseSymbolForScrutinee` — a genuinely separate code path that
  needed its own copy of the privacy check. This is the path that actually
  broke first when reproducing the issue: every nullary-only enum (like
  `enum Status { case Active; case Done }`) or nullary union case can
  *only* be matched this way, so an enum-case bare head never reached
  `unionCaseSymbolForScrutinee` at all.
- `checkRecordPatternHead` — a `PRecord` pattern head (`case Point { x = a,
  y = b } -> …`).

## Fix

In each of the three, moved the existing `symbolIsPackagePrivateBinding` +
`checkImportedVisibility` privacy check out from inside the
`flatSegs.count >= 2` / `segs.count >= 2` ("qualified head") guard so it
runs for both a qualified and a bare head; the T0020 reachability check
(`reportUnimportedQualifiedPackage`) stays qualified-only, per D141's bare
carve-out above. Same ordering as the existing qualified-head checks:
privacy (T0097) before reachability (T0020), and the mismatch check
(T0122/T0137) for a wrong qualified head runs first when there is one.

## Tests

Nine new cases in `lyric-compiler/lyric/typechecker_self_test.l`:
bare private record head (T0097), bare private union case head with a
payload (T0097, `PConstructor` path), bare *nullary* private union case
head (T0097, `checkBareCasePatternScrutinee` path — a distinct regression
from the payload case above), bare private enum case head (T0097, also
the nullary path), three same-package clean cases (record/union/enum — a
same-package private type is never flagged), a public-record-from-another-
package bare-head clean case (no T0097, no T0020 — confirms D141's
carve-out is intact), and the previously-untested "right record name,
wrong qualifier" T0137 branch of `checkRecordPatternHead` (`Wrong.Point`
against a reachable public `Lib.Geo.Point`, raised in the same review).

## Verification

- `make lyric` — clean build (stage 1 + AOT + stdlib + self-hosted
  compiler DLL staging).
- `make self-test NAME=typechecker` — 572 tests, 0 failures (9 new).
- `make self-test NAME=parser` — 148 tests, 0 failures (parser untouched).
- `bash scripts/ci/compiler-self-tests-batch.sh` — full pass, no failures.
- `bash scripts/ci/jvm-generics-self-tests-batch.sh` — full pass, no
  failures.
- Every `lyric-*/lyric.toml` and `examples/*/lyric.toml` manifest restored
  (NuGet-bearing ones first: lyric-mail, lyric-docker, lyric-db,
  lyric-jobs, lyric-web, lyric-grpc, lyric-mq, lyric-aws-secrets,
  lyric-aws-xray, lyric-session) and run through
  `lyric test --manifest <m> --target dotnet`; no in-repo code triggered
  the new T0097 checks (every existing pattern head in the tree matches
  its scrutinee's own, reachable, correctly-visible type).

## Docs updated

- `docs/01-language-reference.md` §3.1 and §4.2/§9.2 — the privacy rule now
  says explicitly that it fires for a bare pattern head, not only a
  qualified one, and explains why (a `pub` wrapper function can return a
  private type/case with no diagnostic at its own call site).
- `book/chapters/appendix-b-quick-reference.md` — T0097's row now says
  "qualified or bare".
- `book/chapters/06-visibility-and-modules.md` — added a paragraph to the
  existing visibility walkthrough covering the bare-head shape.
- No decision-log entry: this closes a documented follow-up gap
  (D-progress-1012 §Scope, D-progress-1015's own "bare head needs neither
  check" reasoning) using the exact mechanism those entries already
  established, rather than introducing a new design.
