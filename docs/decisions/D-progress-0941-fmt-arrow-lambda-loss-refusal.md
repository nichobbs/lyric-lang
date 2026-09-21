# D-progress-941 — `lyric fmt` refused to format any file containing a paren-arrow expression-bodied lambda (`(v) -> v`); fixed by preserving its spelling instead of brace-wrapping it (#6869)

**Status:** shipped

**Context.** Issue #6869: `lyric fmt --write` refused to reformat ANY
file containing a lambda literal written in the paren-arrow,
expression-bodied form — `val f = (v) -> v` — with `FmtStructureChanged`
from `Lyric.Fmt.formatSourceChecked`'s loss-check. This is not a narrow
warning on the offending lambda; the entire file is left untouched, so a
single such lambda anywhere in a file blocks `lyric fmt` from applying
any other, unrelated formatting fix in that file too.

**Root cause.** Lyric's grammar has two spellings that both parse to the
identical `ELambda(lambdaParams, body: Block)` AST node:

- brace form: `{ v -> v }` (`parseLambdaExpr`), and
- paren-arrow form: `(v) -> v` (`parseArrowLambdaTail`), which wraps the
  bare expression body in a synthetic one-statement `Block` whose `span`
  is set to exactly the expression's own span (`Block(statements = [SExpr(e)],
  span = e.span)` — no surrounding braces at all).

`Lyric.Fmt`'s `exprLambdaMulti`/`lambdaInlineStr` (`fmt_core.l`) always
rendered `ELambda` in brace form, regardless of which spelling produced
it. For `(v) -> v` this printed `{ v -> v }` — a different code-token
sequence (`(`/`)` replaced by `{`/`}`, and a token added). `formatSourceChecked`'s
`codeTokens` comparison (§7 in `fmt.l`) correctly does an exact
positional token-sequence diff of input vs. output specifically to catch
a formatter change that alters meaning (e.g. an inserted `{ }` that
rescopes a binding) — so it correctly flagged this transformation as a
structural change and refused to write, exactly as designed. The bug was
the formatter unconditionally canonicalising to brace form in the first
place, not an over-broad safety check: the two spellings are AST-identical
and the paren-arrow form should have round-tripped losslessly.

**Fix.** `fmt_core.l` gains `lambdaBodyIsBareExpr(body: Block): Option[Expr]`,
which detects the paren-arrow spelling purely from the AST already in
hand — no new field on `ELambda` (which would have needed a `_`
added at each of its ~40 positional match sites across both backends,
mono, the weaver, alias/type-alias resolution, wire expansion, the mode
checker, etc. — the same blast radius `EIf`'s existing `thenForm: Bool`
field has at every one of *its* ~114 sites). The detector compares
`body.span` against the single statement's own expression span: a
paren-arrow body's synthetic `Block` has `span == e.span` exactly, while
a real `{ … }` block (always produced by `parseBlock`) has `span`
starting at the `{` token, strictly before its first statement. That
span equality is a reliable, already-available signal.

- `lambdaInlineStr` renders `(params) -> expr` instead of `{ params -> expr }`
  when `lambdaBodyIsBareExpr` matches.
- `exprLambdaMulti` delegates to a new `exprArrowLambdaMulti` for the
  same case, which breaks the body onto its own indented line under a
  bare `(params) ->` opener — mirroring `exprQuantMulti`'s where-guard/body
  split — and never introduces a brace pair (introducing one would
  reproduce the exact bug this fixes).
- `exprStartsWithBracket` (the helper `blockLines` uses to decide whether
  a statement needs a `;` re-inserted before it so re-parsing doesn't
  merge it into the previous statement's trailing expression — the same
  hazard `EParen`/`ETuple`/`EList` already guard against) now also
  recognises a paren-arrow lambda, since it starts with `(` too. Without
  this, a paren-arrow lambda used as a bare statement right after another
  statement could re-parse as a call on that statement's trailing
  expression.

A closely related spelling is intentionally left unfixed here: a
paren-arrow lambda whose body is an *explicit* `{ … }` block
(`(v) -> { v > 0 }`, parsed via `parseBlock` because the token after `->`
is `{`) still has the identical bug, since `lambdaBodyIsBareExpr`
correctly returns `None` for a real block (its span starts at `{`, not
at the inner expression) and the formatter still renders it in brace-only
form. Distinguishing that case needs to know whether the lambda's own
*opener* was `(` or `{`, which the `Block`'s span alone can't answer —
either the `ELambda`-field approach this fix avoided, or a source-text
lookback fmt_core.l's lambda renderers don't currently have access to.
Filed as #7151 (a repro report with a suggested direction, not fixed
here) rather than scope-creeping this PR, per `CLAUDE.md`'s "file a
tracked issue with a concrete plan" policy — the same policy #6869
itself was filed under.

Brace-form lambdas (including ones whose body happens to be a single
bare-expression statement, e.g. `{ v -> v }`) are unaffected —
`lambdaBodyIsBareExpr` only matches the synthetic no-brace `Block` shape
a paren-arrow lambda actually produces, so `{ v -> v }` keeps its own
spelling.

**Verification.** New `fmt_self_test.l` cases: a single-param paren-arrow
lambda (`(v) -> v`) round-trips and keeps its spelling instead of being
refused; multi-param (`(x, y) -> x + y`) and zero-param (`() -> 1`) arrow
forms round-trip; the brace-form counterpart (`{ v -> v }`) still
round-trips in its own spelling (not flattened to arrow form); a
paren-arrow lambda whose body overflows the width budget breaks after
the arrow without introducing a brace pair; a paren-arrow lambda used as
a bare statement round-trips losslessly (`exprStartsWithBracket`
coverage). Validated with `make stage1-fast` (self-hosted DLL rebuild)
plus a from-scratch `make lyric` build so `make self-test NAME=fmt` runs
for real against the new code, matching the loop this repository's
`CLAUDE.md` documents for front-end changes.

**Related:** #2280 (formatter/parser losslessness tracker); D-progress-874
(#6828/#6829, the most recent prior `Lyric.Fmt` AST-fidelity fixes in the
same losslessness family); D-progress-904 (#6833/#6832, the sibling
`Lyric.Doc`/`Lyric.Weaver` fixes from the same review pass).
