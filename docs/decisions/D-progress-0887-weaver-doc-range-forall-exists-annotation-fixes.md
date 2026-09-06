# D-progress-887 — `Lyric.Weaver`'s `args.<field>` rewrite now descends into range expression bounds (and `forall`/`exists` binders); `Lyric.Doc` catches up to three `Lyric.Fmt` AST-fidelity fixes (annotation positioning, range bounds) (#6833, #6832)

**Status:** shipped

**Context.** Two adjacent gaps surfaced during review of #6828/#6829's
`Lyric.Fmt` losslessness fixes (#2280), tracked separately as #6833 and
#6832 since neither is caused by nor in scope for those PRs:

1. `Lyric.Weaver`'s expression rewrite walk (`rewriteExpr`,
   `weaver/weaver.l`) classified `ERange` as a leaf, so the mechanism
   that substitutes aspect-template `args.<field>` references into a
   woven function body (D115/docs/56) never descended into a range
   expression's `lo`/`hi` bounds. An aspect template's advice writing a
   range referencing `args.<field>` as a bound (e.g. `for i in
   args.start .. args.stop`) would silently not get the substitution.
2. `lyric-compiler/lyric/doc/doc.l`'s signature generator has the same
   "trailing annotation rendered/dropped incorrectly" bug shape that
   #6829 (D-progress-874) just fixed for `Lyric.Fmt`: `opaqueSignature`
   rendered `OpaqueTypeDecl.annotations` (a TRAILING annotation the
   grammar places after the name, e.g. `opaque type User @projectable`)
   as a LEADING line instead of inline after the header, and `fieldStr`
   dropped a field's annotations (both leading and trailing) from
   `lyric doc` output entirely.
3. `doc.l`'s `TRefined` type-expression renderer, and separately
   `distinctSignature`, both dropped range-bound text — `typeStr`'s
   `TRefined` case always rendered the literal placeholder `" range
   ..."` regardless of the actual bounds (affects a refined type
   appearing as e.g. a field's type), and `distinctSignature` never
   read `DistinctTypeDecl.rangeClause` at all, so a range-subtype
   declaration (`type Age = Int range 0 .. 150`) documented as bare
   `type Age = Int`. `Lyric.Doc` is a separate AST consumer from
   `Lyric.Fmt` and wasn't touched by #6828/#6829's fixes.

**Fix.**

- `weaver.l`: added an `ERange` case to `rewriteExpr` plus a new
  `rewriteRangeBound` helper that recurses into `lo`/`hi` for all four
  `RangeBound` variants (`RBClosed`, `RBHalfOpen`, `RBLowerOpen`,
  `RBUpperOpen`), each of which now correctly triggers the existing
  `tryMemberRewrite` substitution when a bound is itself `args.<field>`.
  A claude-review pass on this PR found the identical leaf-treatment gap
  one layer up: `EForall`/`EExists` were also leaves in `rewriteExpr`,
  and `rewriteContractClauseArgs` calls this same function on `requires:`/
  `ensures:` clauses — so an aspect's contract clause referencing
  `args.<field>` inside a `forall(...)`/`exists(...)` binder's
  `whereExpr` or `body` had the same never-substituted bug. Added
  matching `EForall`/`EExists` cases recursing into `whereExpr`/`body`
  (`PropertyBinder` carries only `name`/`ty`, no expression of its own,
  so nothing else needs it).
  Pattern-side `PRange` bounds do NOT need the equivalent treatment —
  `docs/grammar.ebnf`'s `RangePattern` production restricts pattern
  range bounds to constant forms post-parse, so `args.<field>` (a
  runtime member access) can never appear there; there is also no
  pattern-rewriting infrastructure in the weaver at all today (match
  patterns are copied through unchanged), so this is a non-issue rather
  than a second gap to close.
- `doc.l`: `opaqueSignature` now renders `od.annotations` inline via a
  new `annotationsInlineSuffix` call (reusing `Lyric.Fmt`'s public
  helper — `doc.l` already imports `Lyric.Fmt`) instead of as leading
  lines. `fieldStr` now splits `f.annotations` at `f.annotations.count -
  f.trailingAnnotationCount` (mirroring `Lyric.Fmt.fieldMemberLines`),
  rendering the leading group as their own line(s) above the field via
  `Lyric.Fmt.annotationLines` and the trailing group inline after it via
  `annotationsInlineSuffix`, instead of dropping every field annotation
  unconditionally. `typeStr`'s `TRefined` case now renders the real
  bound via `Lyric.Fmt.rangeBoundStr` instead of the `"..."` placeholder.
  `distinctSignature` now reads `dt.rangeClause` and renders it via
  `rangeBoundStr` in the same `= <underlying> range <bound> derives
  <...>` order `Lyric.Fmt.distinctDoc` uses.

**Verification.** New `weaver_self_test.l` case: an `@inline_template`
aspect whose advice iterates `for i in args.start .. args.stop`
rewrites both range bounds to the target function's bare parameter
names, asserted via new `rangeBoundMentionsPath`/`rangeBoundHasMemberAccess`
helpers added to the existing `exprMentionsPath`/`exprHasMemberAccess`
walkers (which had the identical `ERange`-as-leaf gap — needed fixing
too, or the test couldn't have caught a regression either way). A
second `weaver_self_test.l` case covers the `EForall`/`EExists` addendum:
a matched function's `requires:` clause containing `forall(i: Int) where
i < args.limit implies i >= 0` has `args.limit` rewritten to the target
function's bare parameter name after weaving. New `doc_self_test.l`
cases: an opaque type's trailing `@projectable`
renders inline immediately after the header rather than on a leading
line; a record field's trailing `@hidden` is preserved instead of
dropped; a refined field type renders its real range bound instead of
the `range ...` placeholder; a distinct range-subtype declaration
renders its range bound instead of omitting it.

This sandbox cannot build `./bin/lyric` from source (GitHub release
download is network-policy-blocked) and `lyric test` links precompiled
compiler-package DLLs rather than recompiling from source for files
under `lyric-compiler/lyric/` (the `LYRIC_LOAD_COMPILER=1` recompile
path `lyric test` used historically was retired for `@test_module`s
that import `Lyric.*` compiler packages, per #2364 Stage 5 — see
`emitTestLinked` in `cli_test.l`), so the new self-test cases could not
be exercised via `lyric test` here. Verified instead with
`LYRIC_LOAD_COMPILER=1 lyric run` debug scripts (a plain program outside
the compiler tree, which DOES recompile `Lyric.Weaver`/`Lyric.Doc` from
source) calling `weaveFileWithDiags`/`generate` directly and printing
the woven AST / generated Markdown; all four scenarios above were
confirmed by hand before being written up as the self-test cases that
will run for real in CI's from-source `make lyric` build.

**Related:** #2280 (formatter/parser losslessness tracker); #6828/#6829
(D-progress-874, the `Lyric.Fmt` fixes whose review surfaced these
`Lyric.Doc`/`Lyric.Weaver` gaps); D115/docs/56 (the `args.<field>`
rewrite mechanism this closes a gap in). See also D-progress-886, the
sibling parser fix from the same session.
