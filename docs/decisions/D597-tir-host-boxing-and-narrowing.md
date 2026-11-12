# D597 - A host call's arguments box to `object`, narrow to small host integers and pass `Float` as `Single` (docs/70 phase 3a, #8613)

**Status:** shipped; extends D600.

## Context

After D600 the census still counted "an extern call no host overload fits" for calls such as `Obj.Equals(42, 42)` (an `Int`
for an `object` parameter), an `Int` or `Long` for a `short`, `ushort`, `uint`, `ulong` or `sbyte` parameter, and a `Float`
for a `float` parameter. The MSIL resolver (`scoreSigType`) accepts all three: `object` takes anything, the small integer
types take an `Int` or `Long` with a range check (#8482), and a host `float` is `System.Single`.

## Decision

`build_host.l` adds `hostBoxKind`, which answers `CvBoxToHost(host)` for a value passed as a host `object`, an `Int` or
`Long` passed as `System.SByte`, `Int16`, `UInt16`, `UInt32` or `UInt64`, and a `Float` passed as `System.Single`. The
operand keeps its Lyric type and the node has the host type. The conversion ranks below every widening in the overload
score (a widening scores 1 per argument, boxing and narrowing 0), as the host's own resolution orders them, and an
overload that takes the Lyric type itself still wins. The narrowing is range checked by the backend that lowers the
conversion, as the MSIL resolver specifies today. The verifier checks that a `CvBoxToHost` node has the host type and that
its operand is not already of it.

D600's remark that narrowing "is not built and stays counted" no longer holds for the five types above.
