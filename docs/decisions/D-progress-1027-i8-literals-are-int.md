# D-progress-1027 — Signed literal suffixes span their signed range; `i8` literals are `Int` (#7847)

**Status:** shipped

## Context

The lexer bounded signed-suffixed literals by the 64-bit range only, so
`3000000000i32` wrapped and `300i8` compiled as 300. Fixing that raises two
questions the language reference did not answer: which literals the narrow
signed suffixes admit, and what type an `i8` literal has.

The type checker typed `i8` literals as `Byte`. `Byte` is unsigned
(`0 ..= 255`), so the signed `i8` range cannot be a `Byte` range: `-1i8` was
a `Byte` holding -1, printed -1 from a local but 255 after a round trip
through a `Byte[]` on the JVM, and compared unequal to `255u8`. `i16`
literals were already `Int`, because Lyric has no 16-bit type.

## Decision

1. A signed suffix bounds its literal by the signed range of its width
   (`i8`: `-128 ..= 127`, `i16`: `-32768 ..= 32767`, `i32` and `i64` their
   usual ranges); an unsuffixed literal is bounded like `i64`. Anything
   else is `L0010`, naming the range.
2. A literal's digits are a magnitude in every base, never a bit pattern.
   `0xFFi8` is 255 and out of range. This matches `u64` (#7839) and
   unsuffixed literals, where `0xFFFF_FFFF_FFFF_FFFF` is `L0010`.
3. A signed minimum is written as a unary minus applied to the magnitude
   one past the maximum, in any base (`-128i8`, `-0x8000_0000i32`). That
   magnitude is accepted only as the direct operand of the minus. This
   extends the `-9223372036854775808` rule (#425) to every signed suffix
   and to based literals.
4. `i8`, `i16` and `i32` literals are `Int`; `i64` literals are `Long`.
   The narrow signed suffixes bound the value but have no type of their
   own, because Lyric has no 8- or 16-bit signed type. `u8` is the `Byte`
   suffix.

## Alternatives rejected

- **Keep `i8` as `Byte` and store negative values as their bit pattern**
  (`-1i8` is `Byte` 255). This makes `-1i8` print 255 and needs a special
  case in constant folding for one suffix, when `u8` already writes every
  `Byte` value.
- **Keep `i8` as `Byte` and bound it by `0 ..= 127`**. This makes `-128i8`
  illegal, which contradicts the name of the suffix.

## Consequences

No compiler, standard library or ecosystem source used a negative or
out-of-range `i8` literal. The one `i8` list literal in a self-test, which
was testing `Byte` literals, now uses `u8`.
