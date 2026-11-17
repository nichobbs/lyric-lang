# D497 - An index of a range subtype or distinct integer is its underlying integer (docs/70 phase 3a, #8613)

**Status:** shipped; extends D496.

## Context

The language reference allows an array index that is "a range subtype of" an integer. A `type Slot = Int range 0 ..= 2` is a distinct type, so `a[s]` had no conversion to `Int` in the builder and was counted as "an argument conversion" (I0002).

## Decision

`buildIndexParts` unwraps an index operand whose type is a refinement (`CvUnrefine`) or a non-generic distinct type over an integer (`CvUnwrapDistinct`) until it is an integer primitive, then keeps that type as D496 does. Anything else still goes through `coerceArg`.

## Results

`tir_build_self_test.l` builds an array read indexed by a `Slot` with 0 I0002 and 0 I0003.
