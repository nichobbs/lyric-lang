# D-progress-972 — T0105 missing-required-field check now covers named-field union-case construction (#7119)

**Status:** shipped

**Context.** `reportMissingCtorFields` (`lyric-compiler/lyric/type_checker/typechecker_exprs.l`),
the shared missing-required-field check added in #6739 (D-progress-924) for
records/opaque types, was only wired into `inferConstruction`'s
record/opaque paths. `inferUnionCaseConstruction` never called it: a
union-case construction that omitted a required named field from an
all-named-args call reached codegen with no diagnostic — the same
invalid-IL hazard #6739 fixed for records, left open for union cases.

Raised as a non-blocking SUGGESTION by `claude-review` on PR #7117 (the
compiler-frontend-resolution integration branch consolidating
#6889/#6892/#6900/#6904/#6914), filed as a tracked follow-up issue (#7119)
per CLAUDE.md's convention of not silently widening an already-reviewed
PR's scope.

**Fix.** New `collectUnionCaseFields(uc, acc)` appends the named
(`UFNamed`) fields of a `UnionCase` to a `List[CtorField]` accumulator,
mirroring `collectCtorFieldsFromRecord`/`collectCtorFieldsFromOpaque`. Two
differences from the record/opaque helpers:

- A union case field never carries a default value (there is no
  `UnionField` default-expression slot at all), so `hasDefault` is always
  `false`.
- A positional (`UFPos`) field is excluded from the accumulated list
  entirely — it can't be supplied by name, so including it (with any
  placeholder name) would make it permanently "missing" whenever the
  all-named-args branch of `reportMissingCtorFields` runs. It doesn't need
  special-casing beyond exclusion: `reportMissingCtorFields` already skips
  its whole check once any positional argument is present in the call
  (mirroring the existing record precedent that mixed positional/named
  under-application is out of scope), and a purely-positional case invoked
  with all-named args (which can't actually name any real field) falls
  through the existing `hasUnknownName` guard instead.

`inferUnionCaseConstruction` gained two new parameters: `args: List[CallArg]`
(threaded through from its three call sites, mirroring `inferConstruction`'s
existing signature) and `checkMissingFields: Bool`.

**The `checkMissingFields` gate — why it's needed.** `inferUnionCaseConstruction`
has three call sites:

1. `inferExpr`'s bare-name-symbol-reference arm (`typechecker_exprs.l`
   around line 2465): infers the type of a bare union-case name used as an
   expression on its own — not necessarily as a call. Per its own existing
   comment, this exists because a call's *callee* expression (`fn` in
   `ECall(fn, cargs)`) is generically inferred as a standalone step before
   the enclosing `ECall` arm re-infers the whole call with the real
   arguments and wins; this site always runs with an empty argument list,
   whether or not the case turns out to be part of a real call with real
   arguments.
2. `inferExpr`'s `ECall` arm (`unionCaseSymbolOf` match, around line 4914):
   the real call-site inference, with the real `args`/`argTypes`.
3. `inferExprExpected`'s `ECall` arm (`unionCaseSymbolForScrutinee` match,
   around line 5425): the expected-type-aware real call-site inference
   (used for e.g. a `match` arm body with a known expected type), also with
   real `args`/`cargTypes`.

The first version of this fix ran the missing-field check unconditionally
and broke 4 existing tests (`generic union ctor typed`, `match nullary no
shadow`, `interface upcast in result`, `union case with nested generic
field infers parent type`, `constructing a real union case is still clean
(#6838 guard)`) — every one of them constructs a field-having case by name
(e.g. `Sm2(value = "s")`, `OpenFailed(message = "x")`). Call site 1 runs
for `Sm2`/`OpenFailed` as the callee-expression placeholder step, with a
genuinely empty argument list — the check saw a case with required fields
and zero supplied arguments and (correctly, in isolation) reported every
field "missing", even though the real, correctly-populated construction
check was about to run moments later at call site 2 or 3. `checkMissingFields`
is `false` only at call site 1 and `true` at call sites 2 and 3, so the
placeholder step never runs the check at all — matching its own "the
enclosing `ECall` arm re-infers with actual arg types and wins" comment,
which already implied its own result (including any diagnostics) is
provisional and superseded.

**Verification.** New tests in `typechecker_self_test.l`: a union case
missing a required field emits T0105; all-fields-supplied stays clean; a
positional-arg construction (under-applied) does NOT spuriously fire T0105
(mirrors the record precedent's `hasPositional` exemption); a nullary
(no-fields) case's bare reference — the call-site-1 placeholder path for a
case that has nothing to miss — stays clean. Full `typechecker_self_test.l`:
430/430 (was 426/426; 4 new cases), no regressions.

**Related:** #7119 (this fix), #6739/D-progress-924 (the record/opaque
precedent this generalizes), PR #7117 (where the gap was originally
flagged).
