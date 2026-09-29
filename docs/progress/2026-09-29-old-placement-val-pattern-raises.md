# `old(...)` placement check walks module `val` patterns and `raises:` types (#7756)

`checkOldPlacement` (`type_checker/typechecker_old.l`, T0080, #7731) walked a
module-level `val`'s type annotation and initializer but not its pattern,
unlike the local `val` case, so an `old(...)` in a range-pattern bound or a
type-test pattern's refinement (`val (a, 0 ..= old(9)) = (1, 2)`,
`val n is Int range 0 ..= old(9) = 3`) went unreported. It also skipped the
types of a `raises:` contract clause. Both are now walked: `oldPattern` on the
module `val`'s pattern, `oldType` on each `raises:` type.

`raises:` itself is unreachable from source: D007 dropped the clause and the
parser never produces `CCRaises` (the grammar keeps `where raises:` reserved,
and the AST case survives only as a pass-through in the alias rewriters, the
weaver and the formatter). No pass type-checks its types. The walk keeps the
T0080 pass total over the AST.

Verified by three new `typechecker_self_test.l` cases: the two module `val`
patterns above (each parses cleanly and reports exactly one T0080), and a
`raises:` clause built directly on a parsed function, whose refined type's
`old` bound reports T0080.
