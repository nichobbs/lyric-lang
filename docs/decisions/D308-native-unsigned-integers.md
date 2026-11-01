# D308 - `ULong` and `UInt` on `--target native`: `i64`/`i32` lowering with the checker's unsigned-operand markers (#8637, #8450)

**Status:** shipped

## Context

`--target native` rejected the `ULong` and `UInt` types (`N0007`, "type 'ULong' is not yet
supported"). The checked `ULong.toLong()` and unsigned `toDouble()`/`toFloat()` conversions
(D278) therefore had no native surface, and #8450 stayed open on one target.

`Lyric.LlvmCodegen` lowers from the AST and carries signedness only in the IR type: `Byte` is
`i8` (unambiguously unsigned), but `Long` and `ULong` would both be `i64`, and `Int`, `Char`
and `UInt` all `i32`. A new `NU64` `NType` variant would touch every `NI64` match (about 310
in `llvm_codegen.l`): scalar arms, ARC and slot conversion, the ABI classifier, lists, maps,
records and unions.

An earlier plan (issue comment on #8637) proposed a new type-checker side table of unsigned
sites, keyed by span, for division, remainder, right shift, ordering comparisons, compound
assignments, stringification, conversions and large literals.

## Decision

Keep the plan's lowering (`ULong` is `i64`, `UInt` is `i32`, so layout, ARC, ABI and
collections are unchanged) but **do not add a side table**. The checker already records every
position whose lowering depends on signedness, since #7812 (`recordUnsignedOperand`,
`argConversionSites`), and `Lyric.Mono.desugarCheckedFile` rewrites each site to the identity
`e.toUInt()` / `e.toULong()` before any backend runs. MSIL and the JVM already read those
markers. Native reads them the same way, through `isUnsignedExpr` (a `.toULong()` /
`.toUInt()` call, a parenthesised one, or a `u16`/`u32`/`u64` literal):

- `<`, `<=`, `>`, `>=` use `icmp ult|ule|ugt|uge`; `/`, `%` and the compound `/=`, `%=` use
  `udiv`/`urem` with only the zero guard (no `MIN / -1` overflow exists).
- `.shr` on an unsigned receiver is `lshr`. The checker now also records the receiver of
  `.shr` as an unsigned operand (the one new checker site); MSIL and the JVM treat the
  marker as the identity it is.
- A range pattern whose bounds are unsigned operands orders unsigned.
- Stringification (`println`, `toString`, interpolation, `String + x`, `format1`-`format4`)
  of a marked operand: a `UInt` zero-extends to a non-negative `i64` and uses
  `lyric_string_from_int`; a `ULong` calls the new runtime helper
  `lyric_string_from_uint(uint64_t)`.
- `.toULong()` / `.toUInt()` zero-extend (`Byte`, `UInt` to `ULong`; `Byte` to `UInt`); a
  `toUInt` of an `i64`-lowered literal truncates to its low 32 bits. A `u16`/`u32` literal is
  an `i32` whatever its magnitude, stored as its two's-complement bit pattern.
- `ULong.toLong()` (checked), `toDouble()` and `toFloat()` need no native code: D278's
  `lowerOverflowChecks` lowering is target-independent. `UInt` conversions go through the
  checker's widening to `ULong` (#7901).

## Consequences

- The `N0007` rejection of `ULong`/`UInt` is gone; range subtypes and distinct types over them
  already carried `isUnsigned`.
- D278's remark that native "does not support the `ULong` type at all yet" is superseded.
- MSIL and the JVM lower `.shr` on `UInt`/`ULong` arithmetically although the language
  reference (section 5) specifies a logical shift; native follows the specification. Tracked
  separately.
- Tests: `llvm_stdlib_self_test.l` (operators, shifts, compound assignment, stringification,
  the D278 conversions including the panic, range patterns, records, lists and maps) and
  `lyric_rt_test.c` (`lyric_string_from_uint`).
