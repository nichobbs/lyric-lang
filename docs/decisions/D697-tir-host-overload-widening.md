# Host overloads: Char widens to int and the most specific equal-score overload wins (docs/70 phase 3a, #8613)

**Status:** shipped; builder only, the checker is unchanged.

## Context

Two JVM auto-FFI self-test bodies were stopped by the TIR gate (D347) for want of an overload the host itself resolves:

- `sb.charAt('a')` on a `StringBuilder`: a Lyric `Char` is the host's `char`, which widens to the `int` parameter. `hostWidenKind` knew integers widening to floating point types but not `Char`.
- `Math.abs(5.toByte())`: a `Byte` widens to the `int`, `long`, `float` and `double` overloads with equal scores, and the builder reported "ambiguous host overloads". The host picks `abs(int)`, the most specific.

## Decision

1. `hostWidenKind` widens `Char` to `Int` and `Long` (`CvWiden`), as the host does for `char`.
2. When two overloads score the same and are not the same parameter list, the one whose every parameter is the other's or widens to it wins (`moreSpecificParams`); only incomparable overloads stay ambiguous.

## Not covered

A Lyric slice passed for a host varargs `Object[]` (`Arrays.asList(values)`, `Objects.hash(values)`, `String.format("%d", values)` with `values: slice[Int]`) stays counted. D472 decides that an `Int` slice is not a host `Object[]`: the representation differs, and the host call needs each element boxed. Accepting it needs a conversion node that says so (a new `ConvKind` with its interface codec, verifier rule and lowering in every backend), which is a design decision for the owner, not a scoring change. A first attempt that let an `Object[]` parameter take any Lyric slice made `Arrays.copyOf(int[], int)` ambiguous against its `Object[]` overload and contradicted D472, and was withdrawn.
