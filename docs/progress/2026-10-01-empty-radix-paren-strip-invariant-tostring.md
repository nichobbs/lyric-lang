# L0016 for an empty radix literal; one paren-strip helper; culture-invariant `toString` of extern structs (#7899, #7894, #7902)

Three follow-ups from the #7854, #7861 and #7898 reviews.

## L0016 is emitted (#7899)

docs/01 §1 and book appendix B documented `L0016` for a radix prefix with no
digits, but the lexer never emitted it. `0x`, `0b`, `0o`, `0x_` and `0b___`
reached the digit parse with an empty body and reported `L0010`, "integer
literal out of range". The frozen log entry in `docs/10-bootstrap-progress.md`
that lists `L0016` as shipped was wrong.

`lexBasedInt` (`lyric-compiler/lyric/lexer.l`) now reports `L0016` when no
digit follows the prefix, ignoring `_` separators:

- The span is the prefix as written (`0x`, `0X`, ...), and the message names
  the base: ``radix prefix `0b` has no binary digits after it``.
- It is the literal's only diagnostic. There is no follow-on `L0010`, and the
  token is an integer literal with value 0.
- A suffix after an empty prefix is consumed into the same token without an
  `L0015`. So `0xu8` and `0xzz` are each one `L0016`. With no digits, the
  suffix adds nothing about the mistake, and reporting it separately would
  give one typo two diagnostics. A valid suffix (`0xu64`) is kept on the
  token.

`lexer_self_test.l` adds three tests: `0x`/`0b`/`0o`/`0X`/`0x_`/`0b___`,
`0xu8`/`0o_i32`/`0xzz`, and `0x + 1` (lexing resumes after the prefix).
All three failed before the fix, with `L0010`. After it, all 80 tests pass.

## Remaining paren-strip copies folded into `Lyric.Parser.stripExprParens` (#7894)

#7861 shared `stripExprParens`. Three copies remained, and each was the same
full strip: recurse through every `EParen` and return the first non-paren
expression. They were `unparenthesized` (`Lyric.Pipeline`'s negated-literal
fold), `unparenthesizedExpr` (`Lyric.Verifier` theory) and `unwrapParenExpr`
(`Msil.Codegen`'s direct-lambda-literal checks). All three are deleted, and
their call sites call `stripExprParens`. Every one of these packages already
imported `Lyric.Parser`.

Some comments still named the deleted `isUnsignedExprMsil`/`isUnsignedExpr`
and the `fctx.unsignedSlots`/`FuncCtx.unsignedVars` tracking. These are in
`range_subtype_self_test.l` and `jvm/unsigned_int_ops_jvm_self_test.l`
(including two test names). They now describe the #7812 mechanism: the
checker spells an operand as `.toUInt()`/`.toULong()`, and the backends
recognise that spelling through `Lyric.Parser.spellsUnsigned`. No behaviour
change.

## `toString` of an extern `Decimal`/`Single` ignores the host culture (#7902)

The new fixed-value assertions in `println_extern_struct_dotnet_self_test.l`
exposed a real bug. On dotnet, `emitStackValueToStringMsil` stringified an
extern value type with `Object.ToString()`, which uses the current culture.
Under de-DE, `toString(Convert.ToDecimal(1.25))` was `"1,25"` and
`toString(Convert.ToSingle(1.5))` was `"1,5"`. `toString(Double)` has been
invariant since #2462.

An extern value type (`MValueTypeRef`) is now boxed and checked at run time:

- If it implements `System.IFormattable`, it is formatted with
  `ToString(null, CultureInfo.InvariantCulture)`.
- Anything else keeps `ToString()`.

`println` shares this path, so `println(x)` still prints `toString(x)`.
`TimeSpan`, `Guid` and `IntPtr` format the same as before, because a null
format under the invariant culture is their default format. `DateTime` keeps
its `"o"` path.

The test builds its values with `Convert.ToDecimal(Double)`/`ToSingle(Double)`,
which do not depend on the culture, and asserts `"1.25"`, `"-1234567.5"`,
`"1.5"` and `"-0.25"`. `scripts/ci/println-stringify-e2e.sh` now runs the
module a second time under `de_DE.UTF-8`.

| Run | Before | After |
|---|---|---|
| Default culture | passed | passed |
| `de_DE.UTF-8` | failed (`1,25`) | passed |

docs/01 §1 and book appendix B state the invariant formatting.

The other half of #7902 is not done. It asked for a native test of
`println()` with no arguments, but the type checker rejects `println()` on
every target (`T0042`, "expected 1 argument(s), got 0"). The zero-argument
branches in the three backends are therefore unreachable for a program that
type-checks. A native test could pass only because the native pipeline does
not stop on type errors: `lyric build --target native` of a file with a
`T0042` still builds and exits 0. Whether `println()` should be legal is a
language decision, and the native diagnostics-gating gap is a separate bug,
so both are left to follow-ups.

## T0147 message helper

`unsignedNegationMessage` now chooses its own `Byte` hint. The type checker's
constant-fold call sites (`typechecker_checker.l`, `typechecker_resolver.l`)
pass only the type name. The expression site calls
`unsignedNegationMessageFor(operand)`, which keeps the `Byte` hint for a
`Byte` range type, since `renderType` spells that type `Byte range ...`.
The messages are unchanged. `typechecker_self_test.l` now checks:

- a `Byte` range keeps the `Byte` hint;
- a `UInt` range does not get the `Byte` hint;
- each constant-fold path names the type it negates and gets the right hint.
