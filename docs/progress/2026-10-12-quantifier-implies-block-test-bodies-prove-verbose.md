# Quantifier `implies { e }` and Bool bodies; test bodies type-checked; `lyric prove --verbose` (#8322, #8308, #8320)

## `implies { e }` is a block; a quantifier body and guard must be `Bool` (#8322)

After `implies`, the parser read the body with `parseExpr`, so
`forall (k: Byte) implies { k == k }` became a quantifier over a *lambda*.
The type checker inferred the body and the `where` guard but never required
them to be `Bool`, so `lyric build` accepted it, `lyric prove` reported only
V0033 ("sort lambda"), and `lyric fmt --write` refused the file (the printer
wrote `-> ` back for the lambda).

The parser now reads a `{` after `implies` as the body's block.  The form is
recorded without a new AST variant: the body is an `EBlock` with
`bodyForm = QBodyImplies`, a combination the parser produced for no other
spelling, and the printer writes it back as `implies { … }` inline and in the
multi-line layout.  `docs/grammar.ebnf`'s `QuantifierExpr` now has one
`QuantifierBody` production shared by `forall` and `exists` (the grammar had
left `implies` out for `exists`, which the parser always accepted).

A `where` guard or body whose type is not `Bool` is **T0132**, the
contract-clause type error ("a forall body must be Bool (got Byte)",
"a forall where guard must be Bool (...)"); an operand already in error or of
type `Never` is not reported twice.  The quantifiers in the standard library,
the ecosystem libraries and `examples/` were all `Bool` already.

Tests: `parser_self_test.l` (the body after `implies {` is a block, after
`implies e` an expression), `typechecker_self_test.l` (T0132 for an `Int`
body, a braced `exists` body and a guard; none for `Bool` bodies),
`fmt_self_test.l` (`implies { … }` round-trips for `forall` and `exists`,
with a `where` guard, and in the long layout), and
`examples/prove-type-check/nonbool_quantifier.l` in `prove-type-check.sh`.

## The type checker checks `test` bodies (#8308)

`registerItem` registered a `test "…" { … }` item and nothing checked its
body, so an ill-typed test passed `lyric build` and `lyric prove`'s type-check
gate, and only `lyric test` reported it, after `Lyric.TestSynth` had rewritten
the test into a function.  The checker now checks each test body as
`Lyric.TestSynth` compiles it: the body of a parameterless `Unit` function in
the module's scope (`checkTestBody`).  `Lyric.TestSynth` keeps the file's
imports and declarations unchanged and turns each `fixture n[: T] = e` into
`val n[: T] = e`, so the checker registers a fixture as that `val`
(`fixtureAsVal`) and checks its initialiser as a `val`'s; a test body sees the
same names under every command.  The `DKFixture` symbol kind, which nothing
read, is gone.

Sweep: `lyric prove` (its type-check gate) over every non-compiler
`@test_module` reported no new error in a test body; the remaining failures
are target- or feature-specific files checked without their target/features,
unrestored dependencies, and an unrelated verifier crash on two `@cfg`-gated
functions of one name.

Tests: `typechecker_self_test.l` (an ill-typed call in a test body is reported
at its own line, an unknown name is T0020, a body reading fixtures is clean,
a fixture's initialiser is T0060 when it does not match its type), and
`examples/prove-type-check/illtyped_test.l` in `prove-type-check.sh`.

## `lyric prove --verbose` (#8320)

`--verbose` (`-v`) was parsed and ignored.  It now prints, for each
obligation, after the diagnostics and before the `N/M obligations discharged`
line: a result line `goal <n>: <label> (<kind>) at <line>:<col>: <outcome>
[<decided by>]`, the goal's SMT-LIB query, and the solver's raw response,
indented under `;;` headings.  The verifier keeps that response: the new
`SolverExchange` (`Lyric.Verifier.dischargeExchange`) carries the outcome,
who decided it (`z3`, `cvc5`, `trivial discharger`, `no solver`) and the
solver's output and stderr, and `ProofResult` gains `decidedBy`/`response`.
An obligation that cannot be translated (V0033) has no query, and says so.

`--verbose` with `--json` is an error (the JSON document is the whole of the
output; `--proof-dir` gives each query a file and `smtPath`).  With
`--explain --goal N` it prints that goal's block after the explanation; in
project mode it prints each file's goals before that file's count.

Tests: `prove-type-check.sh` checks the result line, query and response of a
discharged goal, a refuted goal's `sat`, `--explain`, project mode and the
`--json` refusal.

Docs: `docs/01` §6.3, §13.2 (test runner), §13.3 (verifier output) and the
formatter notes; `docs/grammar.ebnf`; `docs/15` §8.1; book chapters 1 and 18;
appendix B (CLI reference and T0132).
