# MSIL: widen Int to Long at every store, and push Byte range bounds as int32 (#7783)

The type checker accepts an `Int` wherever a `Long` is declared (the lossless
`Byte < Int < Long` chain, docs/01 "Numeric / character conversions"), but the
dotnet backend emitted the int32 as is at several store positions: `l = i`
into a local, `r.f = i` into a field (plain, `self`, and generic `Box[Long]`
instantiations, in-bundle and cross-assembly), `x = i` through an `inout`
parameter, into a hoisted `var` cell, and into a declared `result` local. The
compound forms (`l += i`, `box.value *= 2`, `x += i` through `inout`) combined
an int64 with an int32 in `add`/`mul`. A `Byte`-backed range subtype's
`from`/`tryFrom` compared its byte argument against bounds pushed with
`ldc.i8`. All of these are unverifiable IL (ECMA-335 III.1.5): ilverify
reported them as `StackUnexpected ... found Long, expected Int32` in
`mixed_width_arith_self_test`, `generic_record_var_field_self_test`, and
`range_subtype_self_test`.

This was not a runtime truncation. A probe with negative `Int` values and
results beyond the Int32 range printed the correct 64-bit values on dotnet
(CoreCLR's JIT sign-extends the int32 operand implicitly) and on the JVM. The
IL was still invalid and only worked because of JIT leniency.

The fix:
- `emitCompoundCombineMsil` routes the rhs through `coerceCallArgMsil`, as
  its slot-based twin already did (#7343).
- Every plain-store site in `lowerAssignExprMsil` / `emitCellAssignMsil`
  calls `widenIntToLongMsil`, which the binding and argument sites already
  used (#7755).
- `emitDistinctIntBound` loads a `Byte`/`Char`/`Int`-backed bound with
  `ldc.i4`. `pushConfigBoundMsil` gains the same `Byte`/`Char` arms, which
  previously fell through to `ldc.r8`.

The new dual-target `long_store_widen_self_test.l` covers each store form with
a negative `Int` and an out-of-Int32-range result, plus a `Byte range 10 ..= 250`
subtype. Its dotnet DLL, and the three self-tests above, are now verified in
`scripts/ilverify-selfhosted.sh` phase 4.

Not fixed here: an implicit `UInt` to `ULong` widening at an initialise,
assign, pass or construct position sign-extends on both targets, where docs/01
requires a zero-extension. It is a separate, pre-existing cross-target
miscompile that ilverify cannot see, because `conv.i8` is verifiable. See
#7783.
