# D479 - An instance call of a host method passes over a same-named static overload (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`buildExternCall` scored every overload the host metadata gave for a method name and took the best fit. A Java class that declares `static int compute(int)` and `long compute(long)` made `recv.compute(x)` with an `Int` argument pick the static `int` overload (an exact match) over the instance `long` one (a widening), the bug #6765 fixed in the emit path (`findBestInstanceMethod`). The built call then disagreed with the checker's type: the verifier rejected it (I0003 `call-result-type`, expected `Int` but found `Long`), found by the self-tests census in `jvm_auto_ffi_bridge_self_test.l`.

## Decision

A call through a value (the receiver has a recorded host type) scores instance overloads first and passes over the static ones; only when no instance overload fits does it consider the static ones, as before. A call through a type name and a constructor are unchanged.

## Verification

The fixture's census line: `StaticInstanceCollision.App` 2 of 2 bodies built, 0 I0003 (was 1).
