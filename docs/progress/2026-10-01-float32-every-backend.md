# `Float` is IEEE 754 binary32 on every backend (docs/67 G1, #7940)

D155 made `Float` the 32-bit type the reference always said it was. The JVM
already lowered it to `float` (D-progress-464); MSIL and native lowered it to
the 64-bit `double`, so `0.1f32 + 0.2f32` printed `0.30000000000000004` there
and `0.3` on the JVM.

## Front end

- An unsuffixed float literal is a `Float` wherever a `Float` is required:
  the other operand of a `Float`, a `Float` binding, argument (default
  values included), field, return value, list element, range bound or
  pattern. The type checker records each such literal as an
  `ArgConversionSite` (`floatLiteralSiteMethod()`), and `Lyric.Mono`
  rewrites it to an `f32` literal, so no backend has to rediscover the rule.
- The literal denotes the binary32 value nearest its decimal text, rounded
  once. `Lyric.Lexer.float32LiteralValue` rounds the binary64 value to
  binary32 and, when that lands on a binary32 tie, settles it by comparing
  the exact decimal text against the tie point, so double rounding never
  changes the result. Range bounds (`LiteralBound.f32`) and patterns use
  the same function on every backend.
- Contract clauses (`requires:`, `ensures:`, `when:`, `decreases:`) get the
  same rewrite, so `ensures: result == 0.1` on a `Float` function compares
  against the `Float` nearest 0.1; record and opaque invariants get it
  through their synthesized checker function. Protected-type invariants are
  not type-checked at all yet, so they do not (#7988).
- `.toFloat()` is a conversion method on `Byte`, `Int`, `Long`, `Char`,
  `Float` and `Double`, rounding to nearest even, and a `Float` receiver
  takes the other conversion methods a `Double` does.
- A `Float` argument to a `(Double) -> ...` function value now widens with
  `.toDouble()` instead of being rejected with T0043 (D-progress-964), so
  every widening chain converts through a function value.

## Backends

- **MSIL:** `MFloat` (`float32`): `ldc.r4`, `ldind`/`stind`/`ldelem.r4`,
  `conv.r4` after each arithmetic result, `conv.r8` widening for a mixed
  `Float`/`Double` pair, `System.Single` in signatures, boxing, arrays,
  config parsing (`Single.Parse`) and distinct/range subtypes.
- **Native:** `NFloat` (`float`): typed floating instructions, `fpext` and
  `fptrunc`, and `lyric_string_from_float32`. Floating-point range
  subtypes and range patterns now work on native (range patterns compared
  floats with `icmp` before). `Double.toByte()` and `Byte.toDouble()`,
  missing on native, were added alongside the `Float` forms. An integer
  range-pattern bound on a floating scrutinee (`case 0 ..= 1` on a `Float`
  or `Double`) is converted to the scrutinee's width, as the JVM already
  did; MSIL emitted an `int32` against the floating operand.
- **JVM:** `Float` range patterns and literal patterns compare with
  `fcmpl` (a `dcmpl` on a `float` failed verification), and `Float`
  stringification uses the .NET rules below.

## C bindings

`@library` extern funcs (D158) now accept `Float` parameters and results as
a C `float` (#7966): T0151 excluded `Float` only because MSIL and native
carried it as a `double`. `extern_cbinding_self_test.l` calls `ldexpf` on
all three targets.

## Rendering

`lyric-rt` formats `Double` and `Float` the way .NET's `Double.ToString()`
and `Single.ToString()` do: the shortest decimal that parses back to the
value (next to a power of two, where the rounding interval is lopsided, that
can be the neighbour of the nearest decimal; an exact tie goes to the even
digit), fixed-point for a decimal exponent in `[-4, 16]` (`Double`) or
`[-4, 8]` (`Float`), scientific otherwise (`1E+09`, `1.234E-05`), and `NaN`,
`Infinity`, `-Infinity`, `-0`. Native `Double` output previously differed
from .NET's for large and small magnitudes. Native and JVM output were
compared with .NET 10's on every power of two and on 200,000 random bit
patterns of each width. Native matches everywhere except two `Double` powers
of two (`2^-25`, `2^-959`), where .NET's own output does not parse back to
the value (its Grisu3 port uses symmetric boundaries). The JVM matches except
for the smallest subnormals (#7987).

## Ecosystem audit

No stdlib API used `Float` to mean 64-bit. `OTel.recordHistogram` now takes
a `Double` (its buffer already stored one; source-compatible, since `Float`
widens implicitly). `lyric-proto`'s `floatToInt32Bits` binds
`BitConverter.SingleToInt32Bits` directly instead of narrowing a `Double`
first (#5704's workaround). `lyric-db`'s `DbFloat`, `lyric-resilience`'s
`jitterFraction`, `lyric-feature-flags`' `FlagFloat` and the OTel
`sampleRate` already meant 32-bit, or a fraction where 32 bits suffice.

## Verification

`lyric-compiler/lyric/float32_self_test.l` (9 cases: arithmetic, rendering,
the literal rule, contracts and invariants, widening, conversions,
collections, patterns and range subtypes, NaN) passes on `--target dotnet`, `--target jvm` and
`--target native`, and runs in CI on all three. The default-parameter case
lives in `func_default_args_self_test.l` (dotnet and JVM), since native does
not yet fill omitted default arguments (#7985).
`range_subtype_float_jvm_self_test.l` existed only because MSIL had no
`Float` to read a `Float` range subtype back as; its cases moved into
`float32_self_test.l` and `range_subtype_self_test.l`, which run on every
target, and the JVM-only file and its CI step were removed.
