# Formatter comment/escape/lambda fixes and L007 package-wide registry (#7903, #7303, #7151, #7607, #7623)

Three `lyric fmt` bugs and two `lyric lint` L007 gaps are fixed.

**A plain `//` comment between a `///` doc comment and its declaration stays
put (#7903).** The comment sits in the leading trivia of the declaration
keyword, after the doc token, so it was never consumed at the item boundary
and the first nested consumer (a function's parameter list) claimed it,
splitting the signature across lines. `funcDoc` now pops comments before the
function's own span start and emits them between the docs/annotations and the
signature; `itemDoc` does the same for records, exposed records, unions,
enums, distinct types, aliases, protected types, interfaces, `const` and
`val` (`declStartOffset`). Comments between an annotation and the declaration
keyword are covered by the same pop.

**String-literal escapes for invisible characters are kept (#7303).**
`escapeStr` now escapes DEL and C1 controls, format characters (soft hyphen,
U+200B-200F, U+202A-202E, U+2060-206F, U+FEFF), non-ASCII whitespace and
line/paragraph separators, variation selectors, the combining grapheme joiner,
Hangul fillers, the supplementary-plane tag and variation-selector blocks, and
a combining mark with no base character before it. It now walks UTF-16 code
units so supplementary-plane scalars are decoded and emitted as
`\u{XXXXX}`. Visible non-ASCII text is still printed raw. The formatter
cannot reproduce the author's original hex casing or digit count (the AST
holds decoded text); it prints lowercase, at least four digits. `uHex4` is
replaced by `uHexCp` and the unused 32-branch `charCodepoint` was removed.

**Paren-arrow lambdas with an explicit braced body format (#7151).**
`(v) -> { v > 0 }` is AST-identical to `{ v -> v > 0 }` except for spans: the
lambda's own span starts at `(` while the body block starts at `{`, whereas a
brace-form lambda's body block starts at the lambda's own `{`. The renderers
now receive the lambda expression's start offset and use
`lambdaIsParenBlock` to keep the `(params) -> { ... }` spelling, inline and
multi-line. No `ELambda` field was added. `exprStartsWithBracket` treats the
form like the other `(`-leading lambda.

**L007 sees the whole package in project mode (#7607).** `Lint.lintPackage`
(new) builds one type registry per package from every file that declares that
package and lints each file against it; `lyric lint` in project mode
(`--manifest` or discovery) reads all files first and calls it. Files of
different packages never share types. `lyric lint <file>` keeps its single-file
view. Documented in docs/01 section 13.8 and the book.

**L007 follows aliases to generic applications (#7623).** An alias is private
when its right-hand side mentions a private type anywhere (generic head or
argument, tuple, function type), reusing `collectPrivateTypes` with a depth
bound; the alias's own generic parameters shadow package types. New tests cover
`alias H = Box[Int]`, `alias H = List[Private]`, and the `internal` field and
`internal` function cases.

Tests: `fmt_self_test.l` (lambda, escape and comment cases) and
`lint_self_test.l` (alias and multi-file cases).
