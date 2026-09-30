# Signed literal suffixes are bounded by their signed range (#7847)

The lexer bounded a signed-suffixed literal by the 64-bit range only, so
the narrow signed suffixes were never range-checked:

- `val y: Int = 3000000000i32` compiled and printed -1294967296 on both
  targets;
- `val x = 300i8` compiled and printed 300.

Two related holes sat next to it:

- `i8` literals were typed `Byte`, which is unsigned. `-1i8` was a `Byte`
  holding -1: a local printed -1 on both targets, but the same value read
  back from `[-1i8, 2i8]` printed 255 on the JVM, and `-128i8 == 128u8` was
  false.
- A negated `i32` minimum (`-2147483648i32`) reached MSIL as a negated
  `2147483648`, which the literal lowering pushes as a `long`: an `Int`
  slot then received an `int64`.

## Fix

`Lyric.Lexer.parseIntLiteralValue` bounds every signed suffix by its signed
maximum (127, 32767, 2147483647, 9223372036854775807) and an unsuffixed
literal by `Long`'s, in every base; a larger magnitude is `L0010`, and the
message names the range (`integer literal out of range for `i8` (-128 ..=
127)`). The digits are a magnitude, never a bit pattern: `0xFFi8` is 255 and
out of range.

The magnitude one past a signed maximum (`128i8`, `32768i16`,
`2147483648i32`, `9223372036854775808i64`, `9223372036854775808`) is the new
`IntLitMinMagnitude` outcome. The lexer reports `L0010` and keeps the value,
and the parser cancels that diagnostic when it builds a unary minus directly
around the literal (`isSignedMinMagnitude` in `parsePrefixExpr`). This is the
rule `-9223372036854775808` already followed (#425), now applied to every
signed suffix and to hex, octal and binary literals as well
(`-0x8000_0000i32`, and the unsuffixed `-0x8000_0000_0000_0000`, which was
`L0010` before). Bare, parenthesised (`-(128i8)`) or under a binary minus,
the magnitude keeps its `L0010`. The lexer's separate bare-2^63 check and
the signed-only `parseDigits` are gone; `parseDigitsU64` parses every body.

`i8` literals are now `Int`, as `i16` literals always were (D-progress-1027):
the type checker, `Lyric.Mono`'s literal inference, and the MSIL and JVM
list-literal element typing all agree. `u8` remains the `Byte` suffix.

`Lyric.Pipeline.foldNegatedIntLiteral` now folds a negated signed-suffixed
literal into one negative literal, as it already did for unsuffixed ones, so
each backend sizes `-2147483648i32` by its value (`ldc.i4`, an `i32`
constant on native) rather than by its operand.

The compiler, standard library and ecosystem libraries contain no literal
the new rule rejects. The one `i8` use (`list_literal_index_self_test.l`,
whose #5703 case is about `Byte` literals) now uses `u8`. The v0.7.0 seed
still bootstraps the compiler.

## Tests

- `lexer_self_test.l`: the maximum, the minimum's magnitude and the next
  magnitude of `i8`, `i16`, `i32` and `i64` in decimal, hex and binary (and
  octal for `i8`), `0xFFi8`-style bit patterns, the unsuffixed
  `0x8000_0000_0000_0000`, and the range text in the messages.
- `parser_self_test.l`: the minimum of every signed suffix, in decimal, hex
  and binary, is clean under a unary minus; bare, parenthesised,
  binary-minus and below-minimum forms keep `L0010`.
- `typechecker_self_test.l`: the negated minimums type as `Int`/`Long`;
  `i8` literals are `Int` and do not bind to `Byte`.
- New dual-target `signed_literal_suffix_range_self_test.l`: every signed
  minimum and maximum in decimal, hex, binary and octal, through bindings,
  calls, returns, record fields, module values, list literals, match
  patterns and an `Int range -128i8 ..= 127i8` subtype. It runs in the
  compiler and JVM-generics self-test batches and in ilverify phase 4.
