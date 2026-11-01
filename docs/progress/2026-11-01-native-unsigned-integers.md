# `ULong` and `UInt` on `--target native` (#8637, #8450, D308)

`--target native` now compiles `ULong` and `UInt`. They lower to `i64` and `i32` like `Long`
and `Int`, so layout, ARC, the C ABI and collections are unchanged; comparison, division,
remainder, `.shr`, range patterns and stringification read signedness from the identity
`.toULong()` / `.toUInt()` markers the type checker already spells on unsigned operands
(#7812), as MSIL and the JVM do. New runtime helper `lyric_string_from_uint`. The checked
`ULong.toLong()` and unsigned `toDouble()`/`toFloat()` conversions (D278) now work on native
with no backend code: they are lowered before the backend runs.

The type checker records the receiver of `.shr` as an unsigned operand so native can emit a
logical shift. Covered by `llvm_stdlib_self_test.l` and `lyric-rt/test/lyric_rt_test.c`.
Closes #8637; completes #8450 on native.
