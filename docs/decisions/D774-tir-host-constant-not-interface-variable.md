# A static constant of a host class is its own member, not a generic interface's type variable (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`ByteT.MaxValue` and `NetCharT.MaxValue.toInt()` (`auto_ffi_self_test`, #7889, #8225) were stopped by the TIR gate: "the checker gave no usable type for an expression the checker could not type". The checker types the constants of the narrow and unsigned integer types itself, but not `Byte`'s or `Char`'s, so the builder types the read from the host metadata (D444). The metadata resolver reports two candidates for `System.Byte.MaxValue`: the class's constant field (`public const byte`) and the static abstract getter it inherits from `IMinMaxValue<T>`, whose result is the interface's type variable `T` (`EIEArg 0`). `hostChainResult` returns nothing for the whole read when any candidate's result cannot be typed, and `System.Byte` has no type argument for `T`.

## Decision

Two separate causes stopped `Byte` and `Char`, and both are fixed here.

First, the checker gives the name of an `extern type` for a host class it has a Lyric type for (`extern type ByteT = "System.Byte"`) that Lyric type, so `hostChainReceiver` saw a receiver typed as a primitive and never took the host class the name stands for; it now falls back to `hostStaticReceiver` (a bare name of a non-generic `extern type` that no local shadows), so a static member read through the name is the host class's own. A value of a primitive type is unaffected: `hostStaticReceiver` names only a type.

Second, `hostChainResult` leaves out a candidate whose result is a type variable the host class has no argument for (`EIEArg i` with `i >= host.args.count`): the class's own member is the one the read binds. When every candidate is such a variable they are all kept, as before.

## Consequences

`auto_ffi_self_test` 406 and 437 build; no other host read changes, since only a candidate whose result could never be typed is left out. Test: `tir_build_self_test.l`. The receiver fallback alone (the abandoned D772) and the candidate filter alone each left the body stopped; both are needed.
