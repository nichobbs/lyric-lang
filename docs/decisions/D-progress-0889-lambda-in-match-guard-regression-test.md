# D-progress-889 — MSIL codegen: confirmed a lambda literal in a match-arm guard no longer hits "lambda token missing"; added the missing runtime regression test (#6553)

**Status:** shipped

**Context.** #6553 tracked `liftLambdasMsil`'s `collectLambdasBfsExpr` never
walking a match arm's `guard` expression, so a lambda literal living only
inside a guard (`case y if any(xs, (v) -> v > 0) -> 1`) had no lifted
`__lambda_*` token and codegen panicked with `error[T0120] ... lambda token
missing ... liftLambdasMsil pre-pass was not run`.

**Already fixed (review correction).** The actual guard-walk fix in
`collectLambdasBfsExpr`'s `EMatch` arm — visiting `arms[ai].guard` before
the arm body, matching every sibling BFS-style `EMatch` walker in this
file — is attributed in the code's own comment to **#6601** (the parser
generalization that made a guard containing a nested block-statement lambda
parse at all in the first place; the guard-walk was "previously unreachable
in practice" before that parser fix, per the comment directly above the
fix site in `msil/codegen.l`). D-progress-860, despite this entry's earlier
text, is a **different** fix in the same PR batch — bare-paren-lambda
arrow-suppression scoped to tail position in the parser — and does not
itself touch `collectLambdasBfsExpr` or any MSIL codegen file; citing it as
"the actual fix" was a misattribution in this entry's first revision, not
an issue with #6601 or D-progress-860's own content. Neither #6601 nor
D-progress-860 landed a dedicated runtime self-test asserting the
guard-lambda shape actually compiles AND executes correctly (only
front-end parser coverage landed, in `parser_self_test.l`).

**This change.** Adds the missing runtime coverage: a function whose `match`
guard calls `Std.Iter.any` with a lambda literal predicate
(`case y if any(xs, { v -> v > 0 }) -> y + 100`), asserted for both the
guard-true and guard-false paths, in `impl_method_self_test.l` (this
repo's established home for `liftLambdasMsil` pre-pass gap regressions —
see its #6119/#6119-follow-up sections for the impl-method and
protected-type-member precedents). Confirmed green against a from-source
`make lyric` build of current `main`.

**Formatter note (#6869).** The brace-lambda form `{ v -> v > 0 }` is used
instead of the bare-paren sugar `(v) -> v > 0` shown in #6553's original
repro: the two are equivalent for an untyped single parameter, but
`lyric fmt --write` refuses to format ANY file containing a bare-paren
lambda literal at all (aborting with "formatting would change the
code-token sequence (formatter bug)"), verified with a from-scratch minimal
repro unrelated to this file's prior content. The brace form does not
trigger the bug and formats cleanly, so this file's addition needs no
hand-formatting workaround. #6869 remains open as a standalone tracked
issue (out of `group:msil-codegen-correctness` scope) for the bare-paren
sugar form itself.

**Related:** #6601 (the actual guard-walk fix and the parser generalization
that made the guard shape parse at all), D-progress-860
(a different, unrelated parser fix in the same PR batch),
#6869 (the `lyric fmt` bug sidestepped here via the brace-lambda form).
