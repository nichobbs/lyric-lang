# D-progress-891 — JVM codegen: narrow the P0051 gate from D-progress-890 to genuine reserved-keyword diagnostics only (review follow-up, #6953)

**Status:** shipped

**Context.** Automated review of D-progress-890's PR found that `code ==
"P0051"` alone is not a safe filter: `lyric-compiler/lyric/parser/
parser_exprs.l` reuses the P0051 code for three unrelated "expected ')' to
close a parenthesised/tuple/type expression" diagnostics that have nothing to
do with reserved keywords. Since the gate aborts the entire JVM bundle build
on any P0051 match — even for an unreached stdlib package — a self-hosted-
parser gap that happens to trip one of those unrelated sites against bundled
stdlib source would now hard-fail every JVM build instead of staying
advisory, exactly the false-positive class the surrounding
advisory-diagnostics design (and D-progress-890's own "P0051 is never a false
positive" justification) was meant to guard against.

**Fix.** `reservedKeywordDiags` now filters on `code == "P0051"` AND the
diagnostic's message containing the substring "reserved keyword". All three
genuine reserved-keyword call sites (`parser_core.l`'s `parseIdentFor`-style
helper, `parser_exprs.l`'s pattern-position and expression-position arms)
share this substring in their message text; the three unrelated "expected
')'" sites do not.

**Verification.** `jvm_registry_rollback_self_test` 2/2 (no regression — the
genuine reserved-keyword case still aborts the build with the real
diagnostic). `./bin/lyric fmt --write` clean.
