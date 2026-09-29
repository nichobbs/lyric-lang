# `&<expr>` is a compile error (T0141), closing the bitwise-and landmine

Fixes a gotcha catalogued in cloud-agents' `docs/lyric/gotchas.md`: `&` is
NOT bitwise-and, and `x & y` silently compiled to something other than
what it looks like.

## Root cause

`&` is a genuinely dead-end piece of syntax:

- **Grammar**: `&` is a prefix-only operator (`docs/grammar.ebnf`'s
  `PrefixExpr`, alongside `-`/`not`) — there is no infix form at all.
- **Type checker**: `inferPrefix`'s `PreRef` case (`typechecker_exprs.l`)
  just returned the operand's own type unchanged — no validation, no
  distinct "reference" type.
- **MSIL codegen**: `lowerExprMsil`'s `PreRef` case (`codegen.l`) lowered
  the operand and returned it as-is — a complete no-op, byte-identical to
  not writing `&` at all.
- **Native codegen**: `llvm_codegen.l`'s `PreRef` case unconditionally
  `panic`s with `"function references (&f) are not yet supported for
  --target native (pass a lambda instead)"` — confirming `&` was reserved
  for a planned function-reference form, never implemented on any target.

Because `&` has no infix form, `x & y` never parses as one `EBinop`: the
precedence-climbing expression parser reads `x` to completion (nothing
recognizes `&` as a continuation operator), so the surrounding statement
becomes `val z = x` — a complete statement. The parser's block-loop then
silently re-enters `&y` as a SEPARATE statement (a permissive fallback
this codebase leans on for legitimate cases like `if cond { … } \n
nextStmt` — see `parseBlock`'s `case _ -> {}` leniency), which itself
parses fine as a no-op prefix expression and discards `y`'s value with no
diagnostic anywhere. `y` is still evaluated (side effects happen), but its
value never reaches `z`.

An earlier investigation attempted to fix this by tightening the block
parser's statement-separator enforcement in general (requiring a real
`TStmtEnd`/`;` between any two non-block-terminated statements). That
broke ordinary, valid code throughout the real stdlib — plain multi-`var`
sequences and other everyday patterns don't reliably get a `TStmtEnd`
between them either, for reasons not fully understood, so the parser's
leniency there is load-bearing in ways well beyond this one landmine. That
attempt was reverted rather than shipped.

## Fix

Reject `&<expr>` outright, unconditionally, in the type checker
(`inferPrefix`'s `PreRef` case) — new diagnostic **T0141**. This is a much
narrower, safer fix than touching statement-boundary parsing: it doesn't
change how or when two statements can sit next to each other, it just
makes the SPECIFIC expression `&y` (whatever the reason it got parsed as
its own statement) fail to compile. Since `&y`'s only occurrences in real
Lyric source are: (a) a deliberate — but currently entirely
non-functional — use of the planned function-reference syntax, or (b) the
exact silent-data-loss shape from `x & y`, rejecting it outright closes
the landmine with no loss of any real capability. Confirmed via a
whole-repo grep that no stdlib, ecosystem library, or compiler source
actually uses `&` as a live prefix expression (every `&` match outside
comments is inside a string literal — XML entities, query strings, etc.).

The diagnostic fires in the type checker, which is shared front-end code,
so it rejects `&` identically on **all three targets** (`--target
dotnet`, `--target jvm`, `--target native`) before codegen ever runs —
native's own pre-existing `PreRef` panic is now unreachable in practice
(the type checker's B0001 gate stops the build first), left in place as a
defensive fallback.

## Tests

Three new cases in `lyric-compiler/lyric/typechecker_self_test.l` (611
total, up from 608): a bare `&y` prefix expression is `T0141`; the exact
`x & y` landmine shape (`val z = x & y`) is now `T0141` instead of
silently compiling; and `.and()`/`.or()`/etc. (the real bitwise surface)
are confirmed unaffected. `parser_self_test.l` (148/148) and the rest of
`typechecker_self_test.l` re-verified unchanged. Manually verified
end-to-end against a freshly built `./bin/lyric`: `x & y` now fails with
a clean `error[T0141]` on `--target dotnet` and `--target jvm`, and on
`--target native` (which also still separately reports its own
pre-existing `N0007` panic-as-diagnostic, redundant but harmless).
`.and(y)` still runs correctly (`5.and(3) == 1`).

## Docs

`docs/01-language-reference.md` §4.1 and `book/chapters/appendix-b-quick-reference.md`
(both the bitwise-ops line and the T0xxx diagnostics table) document that
`&` in any position, including `x & y`, is now a compile-time `T0141`.
