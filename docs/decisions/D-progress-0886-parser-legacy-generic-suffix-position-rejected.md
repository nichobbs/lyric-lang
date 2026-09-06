# D-progress-886 — Parser rejects the legacy `generic[...]` keyword spelling at suffix (after-name) position instead of silently accepting it there (#6839)

**Status:** shipped

**Context.** `docs/grammar.ebnf` §5.1 scopes the legacy `generic[T]`
prefix spelling to the head-modifier (prefix) position only, before one
of nine specific item kinds' own declaration keyword (`generic[T] func
foo(...)`, `generic[T] record Foo { ... }`, etc.) — explicitly excluding
`ExternTypeDecl`, which has no head-modifier position to put it before.
`parseGenericParamsOpt` (`parser/parser_exprs.l`), shared by both the
one prefix call site (`parser_items.l`'s item-modifier collection loop)
and 11 suffix (after-name) call sites (`parseRecordBody`,
`parseUnionBody`, `parseOpaqueTypeBody`, `parseFunctionDeclBody`,
`parseInterfaceBody`, `parseImplBody`, `parseProtectedTypeBody`,
`parseTypeAliasBody`, `parseDistinctTypeBody`, `parseExternTypeBody`,
`parseNestedImpl`), didn't restrict the `generic` keyword spelling to
the prefix position — every suffix call site also silently accepted
`record Foo generic[T] { ... }`, a spelling the grammar never scopes
there.

D-progress-870 (#6827) gave `GenericParams.legacyPrefixForm` new,
silent-corruption-shaped teeth for this latent gap: for item kinds with
a paired `genLegacyPrefixStr`/`visAndLegacyPrefixStr` formatter call, a
suffix-position `generic[T]` spelling would get reordered to prefix
position on reformat; for `extern type` specifically (no legacy-prefix
rendering path exists there, since it's outside the grammar's
documented supported-kinds list), `et.generics.legacyPrefixForm = true`
made `genParamsStr` silently return `""`, dropping the generic
parameter list from the rendered output entirely. Neither was an active
bug on the shipped `--write` path — `lyric fmt` always goes through
`formatSourceChecked`, whose positional loss-check caught and refused to
write both cases — but the loss-check was acting as an accidental safety
net for a parser gap, not a designed guarantee.

**Fix.** `parseGenericParamsOpt` gained a third parameter,
`allowLegacyKw: Bool`. When `false` and the current token is
`KwGeneric`, it emits a new diagnostic, `P0096` ("the legacy
`generic[...]` keyword form is only allowed before the item's
declaration keyword, not after its name; use `[T]` here"), then
continues parsing the bracketed list as before for error recovery (the
resulting `GenericParams` node still carries `legacyPrefixForm = true`,
but that's moot — a `P0096` diagnostic means the file already failed to
parse cleanly, so it never reaches the formatter's happy path). All 11
suffix call sites now pass `allowLegacyKw = false`; the single prefix
call site (guarded by its own `case KwGeneric ->` match arm, so it only
runs when the token really is `generic`) passes `true`.

**Verification.** New `parser_self_test.l` cases: an independent
`P0096` assertion for every one of the 11 suffix call sites (record,
function, extern type, union, opaque type, interface, impl-flat,
impl-nested, protected type, type alias, distinct type — the extern
type case is the highest-value one, since it's the kind with no
legacy-prefix rendering path at all), plus a prefix-position regression
test confirming `allowLegacyKw = true` is unaffected (zero `P0096`
diagnostics). Manually verified with `lyric run --` debug scripts
printing `ParseResult.diagnostics` directly (this sandbox's `lyric
test` links precompiled `Lyric.Parser` DLLs for compiler-package
imports rather than recompiling from source, per `make lyric`'s
stage1/`selfhosted-compiler` split — `LYRIC_LOAD_COMPILER=1 lyric run`
on a file outside the compiler tree was the only path in this
environment that reliably recompiled the modified parser from source).

**Related:** #2280 (formatter/parser losslessness tracker); #6827/#6828
(D-progress-870, the review that surfaced this latent gap).
