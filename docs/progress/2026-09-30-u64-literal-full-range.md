# `u64` literals span the full unsigned 64-bit range (#7839)

The self-hosted lexer range-checked every integer literal against the
signed 64-bit range, whatever its suffix. `18446744073709551615u64`,
`9223372036854775808u64` and `0xFFFF_FFFF_FFFF_FFFFu64` were all `L0010`,
so a `ULong` from 2^63 to 2^64-1 could not be written as a literal and had
to be computed at run time. The narrow unsigned suffixes had the opposite
hole: `4294967296u32`, `65536u16` and `256u8` were accepted and truncated
silently by the backends.

## Fix

`Lyric.Lexer.parseIntLiteralValue` parses a literal body against its
suffix, for decimal and for `0x`/`0o`/`0b` literals alike:

- `u64` is parsed by `parseDigitsU64`, which accumulates the magnitude in
  two 32-bit limbs so no intermediate product overflows. A value from 2^63
  to 2^64-1 is carried in the token's `Long` as its two's-complement
  pattern (`18446744073709551615u64` holds -1). Above 2^64-1 the lexer
  reports `L0010` with the `u64` range in the message.
- `u8`/`u16`/`u32` are bounded by 255, 65535 and 4294967295; a larger
  magnitude is `L0010`.
- Unsuffixed and signed-suffixed literals keep the signed 64-bit range.
  The special case for `9223372036854775808` (accepted only as the operand
  of a unary minus) no longer fires for `u64`, where 2^63 is an ordinary
  value.

The literal's AST value is that 64-bit pattern, which is what each backend
already loads: `ldc.i8` on dotnet, `ldc2_w` on the JVM (and an `i64`
constant on native). `lyric fmt` reprints the literal's source spelling, so
it round-trips unchanged.

Downstream readers that compare or render a literal's value as signed now
treat a `ULong` pattern as unsigned:

- A `ULong`-backed range subtype orders its bounds unsigned for the
  empty-range check (`T0090`), and an inline `ULong range` binding orders
  its literal unsigned against the bounds (`T0015`). Both diagnostics print
  the unsigned value. `Lyric.TypeChecker.ulongLessThan` and
  `ulongPatternToString` implement this. Runtime bounds checks were
  already unsigned (`clt.un`/`cgt.un`, `Long.compareUnsigned`); the
  `from`/`tryFrom` range message now prints a `ULong` bound unsigned on
  both backends (`[9223372036854775808, 18446744073709551615]`, not
  `[-9223372036854775808, -1]`).
- `lyric prove` translates a `u64` literal above `Long.MaxValue` to the
  integer it stands for (`v + 2^64`) instead of a negative integer.
- The contract metadata no longer offers a `u64` literal above
  `Long.MaxValue` as a cross-package inlinable constant. Its pattern fits
  `Int` (`-1`), so a consumer would otherwise have inlined it as the `Int`
  -1.

The compiler's own sources contain no `u64` literal above `Long.MaxValue`,
so the release seed still bootstraps the new lexer.

## Tests

- `lexer_self_test.l`: `0u64`, `9223372036854775807u64`,
  `9223372036854775808u64`, `18446744073709551615u64` and the underscored,
  hex, octal and binary forms; `18446744073709551616u64`,
  `0x1_0000_0000_0000_0000u64` and larger are `L0010`; unsuffixed and `i64`
  literals keep the signed range; `4294967295u32`, `0xFFFF_FFFFu32`,
  `65535u16` and `255u8` are accepted, and `4294967296u32`, `65536u16` and
  `0x100u8` are `L0010`.
- `typechecker_self_test.l`: `ULong` range subtypes with bounds above
  `Long.MaxValue` (valid, reversed and empty half-open) and inline `ULong
  range` literal checks, with the unsigned values in the messages.
- New dual-target `unsigned_literal_max_self_test.l`: printing, ordering,
  division, remainder and wrapping arithmetic on the new literals; the
  literals through calls, record fields and module values; literal match
  patterns above `Long.MaxValue`; a `ULong` range subtype whose bounds
  are `2^63 ..= 2^64-1`, including its `tryFrom` message; and `u32` literals up to 2^32-1. It runs in the
  compiler and JVM-generics self-test batches and in ilverify phase 4.
