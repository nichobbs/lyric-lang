# D-progress-1015 — Record-pattern heads are now validated

**Status:** shipped

Fixes #7584. Follow-up to D-progress-1012 (#7548), which added qualifier
reachability/privacy checks for union/enum pattern heads and type positions,
but explicitly scoped record-pattern heads out:

> Record-pattern heads (`PRecord`'s own `head: ModulePath`) are **not**
> covered: both places that type-check a `PRecord` pattern
> (`bindPatternTyped`, `checkConstRefPattern`) discard the head entirely and
> resolve fields purely from the scrutinee's type — there is no existing
> validation of the head at all, qualified or not, import-reachable or not.
> Adding one is a separate, larger structural-validation feature, not an
> import-reachability fix; tracked in #7584.

## Problem

A record pattern (grammar §8, `RecordPattern = ModulePath '{' RecordPatternField … '}'`)
carries a head `ModulePath`, exactly like `PConstructor`'s head. Both
`bindPatternTyped` and `checkConstRefPattern`'s `PRecord` arms discarded that
head entirely and resolved fields purely from `unrefine(scrutineeTy)`'s own
`TyUser` — the head text played no role beyond driving the parser's `{`
dispatch. As a result:

```
package App
record Point { x: Int, y: Int }
record Blob { z: Int }
func f(p: in Point): Int {
  match p {
    case Blob { z = a } -> a   // Blob does not describe a Point — silently accepted
    case _ -> 0
  }
}
```

typechecked cleanly, and a qualified head got none of #7548's reachability
(T0020) or privacy (T0097) checks either — `case PkgPriv.Point { x = a } -> …`
against a `Point`-typed scrutinee from an unimported or private package
compiled with no diagnostic.

Codegen (`lowerPatternTestMsil`'s `PRecord` arm, `msil/codegen.l`) treats a
record pattern as "single-shape" — it derives the class to read fields from
directly off `scrutTy`, not off `head`, so a wrong head was never actually
read at codegen time; the field lookup silently resolves via the scrutinee's
*real* type either way. A record head that names something with no matching
field (a union case, e.g.) results in `mapGet(cctx.fieldTokens, rkey)`
returning `None` and the field bind is silently skipped — no crash, but the
pattern is meaningless once past parsing. Rejecting this earlier, at
type-check time, is strictly safer than letting it fall through to a
silently-skipped field bind.

## Decision

Add `checkRecordPatternHead` (`typechecker_exprs.l`), mirroring
`unionCaseSymbolForScrutinee`'s tier-A qualifier check for `PConstructor`
(#6287 Phase B / #7548) — but simpler, since a record has no separate
"case name" layer the way a union case has a parent union name:

- When the scrutinee's type resolves (`unrefine(scrutineeTy)` is `TyUser`),
  look up every symbol named by the head's last segment
  (`symTableTryFindAll`) and find the one whose `DKRecord`/`DKExposedRec`
  declaring `TypeId` matches the scrutinee's own — `typeIdEq` compares the
  record's *base* id, so a generic record instantiation (`Box[Int]`) matches
  its own generic declaration `Box[T]` the same way `fieldsOfRecordInstantiated`
  already does for field resolution.
- No match (head names a different record, a union/enum case, or nothing at
  all) is **T0137** — a new code, the record-pattern counterpart of T0129
  (union/enum-case-vs-scrutinee mismatch).
- A match under a qualified head (`segs.count >= 2`) additionally requires the
  qualifier text to equal the record's own `originPackage`
  (**T0137** again, worded as a qualifier mismatch, if not — there is no tier
  B for records, unlike unions, so a wrong qualifier is unconditionally wrong
  once the record itself is right); then, in #7548's exact order, **T0097**
  for a package-private record (`symbolIsPackagePrivateBinding` +
  `checkImportedVisibility`, checked first, regardless of import) before
  **T0020** for one whose package isn't reachable from this file's imports
  (`reportUnimportedQualifiedPackage`, reusing #7548's shared reachability
  helper).
- A bare (single-segment) head that already resolves to the scrutinee's own
  record needs neither reachability nor privacy: its package must already be
  reachable, because the scrutinee itself could only have been typed as that
  record by importing it (the same reasoning #7548 already relies on for a
  bare union-case pattern head).
- An unresolved/unknown scrutinee (`TyError`, a type variable, `Self`, a
  nullable, …) is left alone — `unrefine(scrutineeTy)`'s non-`TyUser` arm is a
  no-op, so this never cascades a second error onto an already-broken
  scrutinee, and never fires for a generic function body matching on its own
  unresolved type parameter.

`bindPatternTyped`'s `PRecord` arm is the sole call site that reports (mirrors
the #6540 comment already on its `PConstructor` arm: `checkConstRefPattern`
runs the identical pattern purely to recurse field types, via a scratch
`unionCaseSymbolForScrutinee` call, so its own `PConstructor` diagnostics are
never duplicated). `checkRecordPatternHead` has no effect on
`checkConstRefPattern`'s field-type recursion (`recFields` there is resolved
purely from `scrutineeTy`, independent of the head), so `checkConstRefPattern`'s
`PRecord` arm is left unchanged rather than given a pointless scratch call.

## Survey

Every existing `PRecord` (`Head { field, … }`) pattern in-repo — stdlib,
compiler, ecosystem libraries, tests, `docs/`/`book/` code blocks — uses a
**bare, correct, non-generic-or-generic** head matching its own scrutinee's
record (`Box{value}`, `Point{x=a,y=b}`, `Pair{first,second=s}`, `Shape{n}`,
`SmPoint{px,py}`); none use a qualified head, and none match against a
union/enum-typed scrutinee. This new check changes behavior for zero
in-repo code — every existing site keeps type-checking with zero new
diagnostics — while catching a previously-silent shape (a genuinely wrong or
unreachable head) that had no test coverage in either direction before this.

## Scope

No codegen changes: MSIL/JVM/native already read fields off the scrutinee's
*real* type, not off `head`'s text, so a rejected head was never actually
"used" for codegen in a way this fix needed to correct — only to make a
previously-silent, always-safe-but-meaningless shape into a compile error
before it can reach codegen at all.

A side effect worth recording: `docs/grammar.ebnf`'s Q019 note ("the
rejection of patterns that destructure protected types is enforced in the
type/pattern checker") describes intent this fix is the first to actually
deliver for record-brace patterns — a protected type is `DKProtected`, never
`DKRecord`/`DKExposedRec`, so `case ProtBag { count = a } -> …` against a
`ProtBag`-typed scrutinee now hits `checkRecordPatternHead`'s "does not
match" fallthrough (T0137) instead of silently resolving every field to
`TyError`. No in-repo code exercises this shape either way (no test asserted
it was accepted or rejected before this change), so this is a genuine (and
welcome) tightening, not a documented regression.

`docs/01-language-reference.md` §4.2 and `book/chapters/appendix-b-quick-reference.md`
are updated with the new T0137 code and the T0097/T0020 extension to record
heads; `book/chapters/06-visibility-and-modules.md`'s visibility walkthrough
gets the record-pattern-head analog of its existing union/enum text.
