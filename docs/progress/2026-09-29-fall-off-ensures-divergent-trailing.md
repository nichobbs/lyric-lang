# No fall-off `ensures:` check after a divergent trailing `if`/`match` or a constant-true `while` (#7764)

Two cases where the contract elaborator appended a postcondition check that
nothing could reach:

1. `rewriteTrailingSExpr`'s `Unit` path (#3505) always appended the fall-off
   `ensures:` asserts after a trailing expression statement, without the
   `exprAlwaysExits` test its non-`Unit` path already applied (#3842). A
   `Unit` function ending in an `if`/`else` or `match` whose every branch
   returns (or ends in a `while true` nothing leaves) got an unreachable
   check after it. It is now skipped when the expression always exits; its
   returns were already rewritten to check the postcondition.
2. `isLiteralTrue` (#7759) recognised only the literal `true`, so a
   compile-time-true condition spelled otherwise — a module `val`/`const`
   bound to `true`, `1 == ONE`, `not false` — took the "may complete" path:
   an unreachable fall-off check after the loop and an unreachable normal-exit
   loop-invariant check. `canonicalizeConstantLoopConds`
   (`contract_elaborator/const_conds.l`), run at the start of
   `elaborateFileWithInterfaces`, folds each `while` condition and replaces
   one that is always `true` with the literal, so the existing `while true`
   classification applies (and backends see the same loop). The fold is
   sound and narrow: Bool literals, `not`, short-circuiting `and`/`or`,
   `==`/`!=` on constant Bools or integers, ordering on constant integers;
   signed integer literals only, no arithmetic (its overflow depends on the
   operand type); a bare name only when it is a module `val`/`const` of the
   file declared once and bound nowhere else in the file (no parameter,
   local, `var`, pattern, lambda parameter, catch or quantifier binder, or
   field of that name), so a shadowing `var` is never folded.

Neither shape made either backend reject the output in practice: the checks
sit after a `return` or after a loop whose exit branch is still in the
bytecode, and both `ilverify` and the JVM verifier accept that dead code (the
#7759 J008 came from a non-`Unit` trailing value, which a non-literal
`while` condition cannot reach because the checker's divergence rule,
`isStaticallyTrueCond`, still types such a loop as completing). The fix
removes the dead code rather than a verifier failure.

Verified by eight new `contract_elaborator_self_test.l` shape tests (four fail
before the fix: an all-return `if`, an all-exit `match`, `while` over a
constant val, `while` over folded comparisons/negation; the others pin that
a fall-off branch, non-constant, arithmetic, unsigned, non-literal and
shadowed conditions keep the check) and six dual-target runtime cases in
`contract_fall_off_ensures_self_test.l` (satisfying and violating calls for
each shape, including a shadowing `var`), passing on `--target dotnet` and
`--target jvm`, plus `ilverify` of a compiled program with each shape.
