# D428 - A numeric conversion method of a range subtype builds as the underlying primitive's built-in (docs/70 phase 3a, #8613)

**Status:** shipped; extends the conversion methods of range and distinct types (D453).

## Context

`p.toInt()` on `Population` (`type Population = UInt range 1000 ..= 4000000000`) is typed `Int` and records no callee. The builder unwraps the receiver to its underlying `UInt` and converted it to the call's type with the language's implicit conversions, which do not take a `UInt` to an `Int`: the body was counted ("a conversion method whose result differs from the underlying type", I0002): `RangeSubtypeSelfTest::populationValue`.

## Decision

When the unwrapped value and the call's type are both primitives and the implicit conversion does not apply, the method is the conversion itself: the builder emits the built-in of the underlying primitive named as the checker names one on a plain primitive receiver (`UInt.toInt`), applied to the unwrapped value. A conversion between other types stays counted.

## Results

`range_subtype_self_test.l` builds every body (13 of 13; one was counted); a new `tir_build_self_test.l` case covers `toInt` and `toLong` of a `UInt`-backed range subtype and verifies the built bodies.
