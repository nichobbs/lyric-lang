# A static constant of a host class is its own member, not a generic interface's type variable (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`ByteT.MaxValue` and `NetCharT.MaxValue.toInt()` (`auto_ffi_self_test`, #7889, #8225) were stopped by the TIR gate: "the checker gave no usable type for an expression the checker could not type". The checker types the constants of the narrow and unsigned integer types itself, but not `Byte`'s or `Char`'s, so the builder types the read from the host metadata (D444). The metadata resolver reports two candidates for `System.Byte.MaxValue`: the class's constant field (`public const byte`) and the static abstract getter it inherits from `IMinMaxValue<T>`, whose result is the interface's type variable `T` (`EIEArg 0`). `hostChainResult` returns nothing for the whole read when any candidate's result cannot be typed, and `System.Byte` has no type argument for `T`.

## Decision

Four separate causes stopped `Byte` and `Char`, and all are fixed here.

First, the bare name of an `extern type` is the host class itself whatever type the checker gave the name: for a host class it has a Lyric type for (`extern type ByteT = "System.Byte"`) it gives the Lyric primitive or the host type as a value, and `hostChainReceiver` took either as a receiver that is not static, so a static constant read through the name was rejected. `hostChainReceiver` now asks `hostStaticReceiver` first (a bare name of a non-generic `extern type` that no local shadows), so a member read through the name is a static one. A value of any type is unaffected: `hostStaticReceiver` names only a type.

Second, `hostChainResult` leaves out a candidate whose result is a type variable the host class has no argument for (`EIEArg i` with `i >= host.args.count`): the class's own member is the one the read binds. When every candidate is such a variable they are all kept, as before.

Third, a constant the checker leaves untyped may be a two-segment path (`ByteT.MaxValue` where the parser did not form a member access): `openHostChainTy` and the expression builder read it as the static member of the host class the first segment names (`hostStaticPath`). Where the context has settled a wider type than the constant's own (`val i: Int = ByteT.MaxValue`, an `Int` argument), `buildHostStaticReadOf` builds the read at the member's type and converts it.

Fourth, a host `System.Char` result is the Lyric `Char` (`hostElemTy` maps it), not a class the checker would have typed, so `hostChainResult` accepts it.

## Consequences

`auto_ffi_self_test` 406 and 437 build; no other host read changes, since only a candidate whose result could never be typed is left out. Test: `tir_build_self_test.l`. The receiver fallback alone (the abandoned D772) and the candidate filter alone each left the body stopped; both are needed.
