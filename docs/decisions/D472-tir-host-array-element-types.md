# D472 - A host member's array parameter and result name their element type (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

A host member's array parameter or result was the single placeholder host name "an array, pointer or by-reference type" with no element, so `hostBoxKind` (D599, D468) could only accept the slices it was sure of: `Byte` and host values. The wide census left `java.util.Arrays.copyOf(slice[Int], Int)` (`auto_ffi_jvm_self_test.l`) as "an extern call no host overload fits": a slice of `Int` is the JVM's `int[]`, but the signature did not say the host array was an `int[]`. This is the part 3 follow-up "host array element type in `ExternIterElem`".

## Decision

An array of `E` is the placeholder host applied to `E`: `EIEHost("an array, pointer or by-reference type", [E])`. A pointer or a by-reference type keeps the placeholder with no argument. No new `ExternIterElem` case, so no exhaustive match changes in the checker.

- `Jvm.Bridge.jvmElemOfDesc` maps a `[` descriptor to the placeholder applied to its element's mapping (`[I` to `Int`, `[Ljava/lang/String;` to the host `String`, `[[B` to an array of arrays).
- `Msil.Bridge.iterElemOfSig` maps an `STSzArray` the same way.
- `hostBoxKind` accepts a slice or `array[N, T]` for a host array that names its element when `T` is that element (a host `String` element is Lyric's `String`; an `Object[]` takes a slice of host values, reference arrays being covariant). A host array with no element named keeps D468's rule (bytes and host values).

## Not covered

Multi-dimensional rectangular arrays (`T[,]`) and by-reference array arguments keep the placeholder with no element.
