# Std.Math IEEE 754 bit casts; lyric-proto on the JVM

`Std.Math` gains `floatToBits` / `floatFromBits` (`Float` and `Int`) and
`doubleToBits` / `doubleFromBits` (`Double` and `Long`). They keep every bit,
NaN payloads included, through the audited kernel boundary: `BitConverter`
on dotnet, `Float.floatToRawIntBits` / `intBitsToFloat` and
`Double.doubleToRawLongBits` / `longBitsToDouble` on the JVM, and new
`lyric_float_to_bits` & co. in `lyric-rt/src/lyric_rt.c` (`memcpy`) on native.
`lyric-stdlib/tests/math_tests.l` covers them on dotnet and the JVM, a case in
`lyric-compiler/lyric/llvm_stdlib_self_test.l` covers them on native under
AddressSanitizer, and `test_float_bits` in `lyric-rt/test/lyric_rt_test.c`
covers the C side.

lyric-proto declared four `@externTarget`s outside a kernel
(`System.Convert.ToInt64`/`ToInt32`, `System.BitConverter.SingleToInt32Bits`/
`DoubleToInt64Bits`), so every JVM build that used it failed class
verification. `intAsLong` is now `n.toLong()`, `longAsInt` is
`Std.Math.longToInt` (still checked, and every caller range-checks first), and
the bit casts go through `Std.Math`. Its suite passes on dotnet and the JVM,
and `proto` joins `scripts/ci/jvm-ecosystem-suites.sh`.

lyric-otel's histogram `sum` encoder used its own dotnet `BitConverter`
extern and, on the JVM, a stub that panicked. Both are gone in favour of
`Std.Math.doubleToBits`, so all ten `OTel.OtlpCodecTests` pass on the JVM
(nine failed before). lyric-otel's JVM OTLP/HTTP transport is still not
implemented (`OTel.OtlpTransportTests` does not build for the JVM), as its
README says.
