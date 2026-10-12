# `lyric fmt` keeps a quantifier body's form; `lyric prove` counts every outcome, writes SMT queries, rejects unknown options (#8305, #8307, #8309)

## A quantifier body keeps the form it was written in (#8305)

`lyric fmt --write` refused every file with an unbraced quantifier body,
`forall (k: Byte) g(1) == g(1)` as much as `forall (k: Int) k == k` or
`forall (k: Int) where g implies e`: the printer wrapped every body that was
not a block in `{ }`, and the loss check rejected the inserted brace.  The AST
did not record how the body was written, so the printer could not do better.

`EForall`/`EExists` now carry a `bodyForm: QuantBodyForm` (`QBodyBraced`,
`QBodyImplies`, `QBodyBare`), set by the parser and kept by every pass that
rebuilds the node.  The printer writes the body back in its form, inline and
in the multi-line layout (a long bare body goes on the lines below the
binders, a long `implies` body there after `implies`).  A bare body that would
not parse back as the body (it opens with `{` or `implies`, or, after a
`where` guard, with a token that would extend the guard) is braced; only a
body a pass rewrote can be like that.  A comment between the binders (or the
`where` guard) and a bare or `implies` body goes on its own line above the
body; it used to escape into the function's body, and a second format then
changed the file again.

`examples/prove-quantifier-sides/unsound.l` is back to the bare form #8223 was
reported in, with braced twins, and `sound.l` gains bare and `implies`
variants; `prove-type-check.sh` checks each function by its exact name.

Tests: `fmt_self_test.l` round-trips bare bodies opening with a call, a path,
a parenthesised expression, a unary operator, nested quantifiers, the
`implies` and braced forms, a quantifier as a right operand, long bodies of
each form, and the bracing of a rewritten body that would not parse back.

## The `--json` summary counts every outcome (#8307)

`unknown` and `counterexamples` were written as `0`.  They are now counted
from the obligations (`Lyric.Verifier.summaryUnknownCount`,
`summaryCounterexampleCount`), like `total` and `discharged`; the vacuity
checks behind `V0035`/`V0036` stay out of every count.  The other fields
(`file`, `level`, the goals, the diagnostics) were checked against the goal
data and were already right.  `prove-type-check.sh` proves
`examples/prove-json-summary/counts.l` (one discharged, one refuted and one
undecided obligation) and checks each count against the goals listed.

## `--proof-dir` and unknown options (#8309)

Appendix B documented `lyric prove --proof-dir <dir>` from the M4 F#
prover, but the self-hosted CLI never parsed it: the flag and its directory
became source paths.  It is implemented: each obligation's SMT-LIB query is
written to `<dir>/<n>-<label>.smt2` and `--json` gives its path as `smtPath`
(`null` for an obligation that could not be translated, `V0033`, recorded by
the new `ProofResult.translated`).  A run first removes the `.smt2` files already in `<dir>`, so the directory
holds that run's queries only; `--explain --goal N` writes them only once `N`
is known to be in range; and a following option is not taken as the
directory (`--proof-dir --json` is an error).  It needs a source file, like `--json`;
without it nothing is written (the old `target/proofs/` default is gone from
the docs).

An option `lyric prove` does not take is now an error naming it, and a second
source file is an error too (it was ignored).  `rejectUnknownOption` in
`cli_shared.l` is the shared check.  `prove-type-check.sh` covers
`--proof-dir` (files, `smtPath`, report line) and each refusal.

Docs: `docs/01` §13.2/§13.3, `docs/15` Appendix A, book chapters 1 and 18,
appendix B.
