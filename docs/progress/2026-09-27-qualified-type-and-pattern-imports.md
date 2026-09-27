# 2026-09-27 — Qualified type positions and pattern heads need a reachable import too

D-progress-1012, #7548. Follow-up to D-progress-1011 (#7495, #7499), which
scoped type positions and pattern heads explicitly out of its fix.

A qualified type reference (`val c: Std.Rest.RestClient`, a parameter/field/
return type, or a generic type argument such as `List[Std.Rest.RestClient]`)
into a package the file never imports used to type-check silently, the same
gap D-progress-1011 closed for a qualified expression path. It is now
**T0020** (`unknown name 'Std.Rest.RestClient' (package Std.Rest is not
imported; add import Std.Rest)`), same reachability test, same `Std.Core`
exemption. A package-private type in type position is unaffected (still
exactly one T0097, from the existing `checkImportedVisibility` call — this
fix does not duplicate it).

A qualified pattern head (`case Std.Rest.Kind.A -> ...`) matching a
scrutinee whose own union/enum lives in an unimported package gets the same
T0020 now — the existing tier A/B qualifier check (#6287 Phase B) only
validated that the qualifier structurally names the scrutinee's own type,
never that the package is reachable. A package-private union/enum's case
named in a qualified pattern head is T0097 instead, regardless of import,
mirroring the private-receiver rule.

Verified: a plain qualified value read with no call, through a two- and
three-segment package, WITH the import present, runs correctly on both
`--target dotnet` and `--target jvm` (`Lib.Rest.someVal`, `Lib.Net.Rest.
someVal`, `Lib.Net.Rest.Kind.A`, all via a `[project.packages]` manifest
build). WITHOUT the import, the same reference is a pre-existing,
orthogonal MSIL/JVM parity gap in the multi-package project-build bridge
(dotnet silently accepts it, JVM correctly rejects it with T0020) — left
open; see D-progress-1012's "Scope" section. Record-pattern heads (which
have no existing head validation of any kind) are also left open.

Also added (requested during review): a runtime regression test for a
package-qualified distinct-type/range-subtype factory call
(`Lib.Net.Units.Port.tryFrom(n)` through an `import`ed, multi-segment
package, in the same project as the producer) — this already worked
correctly on both targets before this change (real range validation, not a
silent pass-through), so only the test (`scripts/ci/distinct-factory-import-
e2e.sh`, wired into `compiler-self-tests-batch.sh`) was added; no code fix
was needed here (relevant to the in-review #7577, which covers the
*bare*-receiver self-qualified form).

Docs: docs/01-language-reference.md §3.1 and §9.2, book chapter 6, appendix
B (T0020, T0097). Tests: `typechecker_self_test.l` (unimported/imported/
transitively-reachable/`Std.Core`/same-package/private, for both type
position and pattern heads; a #6700 regression guard for the pattern-head
fallback); `scripts/ci/distinct-factory-import-e2e.sh` (new, both targets).
