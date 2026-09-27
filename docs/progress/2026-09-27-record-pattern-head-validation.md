# 2026-09-27 — Record-pattern heads are now validated (#7584)

Fixes #7584, a follow-up gap D-progress-1012 (#7548) scoped out explicitly.

`PRecord`'s own `head: ModulePath` (`case Head { field = pat, … } -> …`) used
to be discarded entirely by both `bindPatternTyped` and
`checkConstRefPattern` — fields were resolved purely from the scrutinee's own
type, so a head naming a different record, a union/enum case, an unimported
package, or a package-private record type-checked silently.

Added `checkRecordPatternHead` (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`),
mirroring `unionCaseSymbolForScrutinee`'s qualifier handling for
`PConstructor` (#6287 Phase B / #7548), called from `bindPatternTyped`'s
`PRecord` arm (the sole diagnostic owner, matching the existing #6540 pattern
for `PConstructor`):

- **T0137** (new code) when the head does not name the scrutinee's own
  record — a different record, a union/enum case, an unresolvable name, or
  the right record under the wrong package qualifier.
- **T0097** (privacy, checked first) for a qualified head naming a
  package-private record, whether or not its package is imported.
- **T0020** (reachability) for a qualified head naming a record whose
  declaring package isn't reachable from the file's own imports — reusing
  #7548's `qualifiedPkgReachable`/`reportUnimportedQualifiedPackage` helpers.
- An unresolved/unknown scrutinee (`TyError`, a type variable, `Self`, a
  nullable) is left alone — never cascades a second diagnostic.
- A bare head against a generic record instantiation (`Box[Int]`) resolves
  cleanly, matching field resolution's existing generic-agnostic `TypeId`
  comparison.

See `docs/decisions/D-progress-1015-record-pattern-head-validation.md` for
the full design, the codegen-safety argument (MSIL/JVM/native record-pattern
codegen already reads fields off the scrutinee's real type, never off
`head`'s text, so this is a pure type-check-time tightening with no backend
changes), and the in-repo survey (every existing record-pattern site uses a
bare, correct head — this change is a no-op for all of them).

## Tests

Eight new cases in `lyric-compiler/lyric/typechecker_self_test.l`:
bare correct, wrong record (T0137), wrong union case as head (T0137), generic
record (no false positive), unresolvable scrutinee (no cascade), unimported
qualified package (T0020), imported qualified package (clean), and
package-private qualified record (T0097).

## Verification

- `make lyric` — clean build (stage 1 + AOT), stdlib bundle, self-hosted
  compiler DLL staging all succeeded.
- `make self-test NAME=typechecker` — 550 tests, 0 failures (8 new).
- `make self-test NAME=parser` — 148 tests, 0 failures (parser untouched by
  this fix; confirms no regression).
- `bash scripts/ci/compiler-self-tests-batch.sh` and
  `bash scripts/ci/jvm-generics-self-tests-batch.sh` — see the PR/session
  notes for pass counts.
- Every `lyric-*/lyric.toml` manifest's `lyric test --manifest <m>` run on
  `--target dotnet` was swept for regressions from the new T0137/T0097/T0020
  diagnostics; none were found (the survey above already established no
  in-repo `PRecord` pattern uses a qualified or mismatched head).

## Docs updated

- `docs/01-language-reference.md` §4.2 (record-pattern head validation rule).
- `book/chapters/appendix-b-quick-reference.md` (new T0137 row; T0097's row
  extended to mention record heads).
- `book/chapters/06-visibility-and-modules.md` (record-pattern-head analog of
  the existing union/enum visibility walkthrough).
- `docs/10-bootstrap-progress.md` Tier status — no update needed; this is a
  type-checker diagnostic fix, not a new bootstrap-tier milestone.
