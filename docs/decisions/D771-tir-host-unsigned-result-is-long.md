# A host UInt32 or UInt64 result the checker types as Long is read with CvFromHost (docs/70 phase 3a, #8613)

**Status:** shipped; builder only.

## Context

`UInt32T.Parse("4000000000")` (`auto_ffi_self_test`, #7890) returns the host's `System.UInt32`, which the checker types as `Long` (zero-extended; a `UInt64` is its bit pattern as `Long`, #8482). The builder gave the call node the checker's type `Long` but the callee's declared result `System.UInt32`, so the verifier rejected the node (I0003 `call-result-type`, "expected extern System.UInt32 but found Long").

## Decision

`hostResultIsCallType` includes `System.UInt32` and `System.UInt64` for a `Long` call type, so the call keeps the host's result type and a `CvFromHost` gives the checker's `Long`, as for the other host results the checker types as a Lyric type without checking it (D359).

## Consequences

`auto_ffi_self_test` body 24 (#7890) builds with I0003 0. Test: `tir_build_self_test.l`.
