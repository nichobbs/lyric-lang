# D451 - The unsigned widening methods are recorded as built-in calls (docs/70 phase 3a, #8613)

**Status:** shipped; extends D362 (built-in callees in the symbol table).

## Context

`b.toUInt()` and `x.toULong()` (the lossless widenings of the unsigned chain `Byte < UInt < ULong`) are typed by an early return in the checker, before the general member path that records a built-in call's name. Every other numeric conversion method records `<Recv>.<method>` under the call's node id (`builtinByNode`); these two did not, so the TIR builder counted each as "a call the checker did not resolve" (I0002). The plugin generator's `__pluginLongToUInt` and `__pluginLongToULong` (`n.toByte().toUInt()`) put the kind in every program that declares a plugin point.

## Decision

The checker records the call under its node id as `Byte.toUInt`, `UInt.toULong` and so on, as the other conversion methods do, before returning the result type. The builder needs no change: a built-in call is built from its recorded name.

## Results

`tir_build_self_test.l` builds `Byte.toUInt`, `Byte.toULong`, `UInt.toULong` and `Long.toByte().toUInt()` with 0 I0002 and 0 I0003.
