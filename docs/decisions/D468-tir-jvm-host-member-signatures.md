# D468 - The JVM resolver answers member signatures with array, float and short results, and the builder takes the host conversions they need (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

D466 made the census build JVM programs for `--target jvm`. That exposed the JVM host-metadata kind: 16 "an extern call the host metadata cannot resolve" and 9 "an extern call no host overload fits" over the four stdlib JVM tests, none a fault of the builder's call rules.

## Decision

- `Jvm.Bridge`'s `resolveMemberSigs` returned `None` for a whole member as soon as one result descriptor had no `ExternMemberType` (`[Ljava/lang/reflect/Method;`, `F`, `S`), so `cls.getMethods()` could not be resolved at all. A result with no direct mapping now takes `jvmElemOfDesc`, the same placeholder the MSIL resolver gives it (`iterElemOfSig`): the host array name for arrays, `java.lang.Float` for `F`, `java.lang.Short` for `S`. The checker-facing `resolveMember` is unchanged.
- `hostUpcastKind` accepts a `String` passed for a host supertype (`CharSequence`, `Comparable`): the host's bases of `java.lang.String` or `System.String` are asked of the resolver.
- `hostBoxKind` accepts a slice or `array[N, T]` of any element for a host array parameter, not only `Byte`: the checker already types every host array result as a slice of its element (D359) and the signature keeps no element type.
- `hostResultNode`: when the checker settles a host call at a host supertype of the host's result (`JString.valueOf(x)` returned as `JCharSequence`), the call keeps the host result type and an upcast gives the checker's. Without it the call node carried the supertype and `call-result-type` rejected it (found by the wide census in `Std.RegexHost`).

## Not covered

A lambda passed for a host functional interface (`Thread.new({ -> ... })`) and a Lyric record that `impl`s an extern interface passed as that interface (`startVirtualThread(ScopeJob(...))`) still count as "no host overload fits". Each needs a conversion kind the model does not have; they are the next slice.
