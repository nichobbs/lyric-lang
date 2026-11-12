# D600 - A host call's arguments widen as the host resolves overloads (docs/70 phase 3a, #8613)

**Status:** shipped; extends D387.

## Context

`tir-census.sh --wide` reported "an extern call no host overload fits" for calls such as `Math.Sqrt(4)` and
`Math.Sqrt(9i64)`: the builder selected an overload by the language's widening (`Byte < Int < Long`, `Float < Double`),
but the host resolves overloads by the CLR's own numeric widening, so an integer argument takes the `double` overload.
The MSIL resolver already scores it that way (`numericRank`).

## Decision

`build_host.l` adds `hostWidenKind`: the language's widening, or an integer type (`Byte`, `Int`, `UInt`, `Long`, `ULong`)
to `Float` or `Double`. The overload score and the argument conversion in `buildExternCall` use it, and the conversion is
a `CvWiden` node, which the verifier checks by its result type and the native lowering emits as an integer to floating
point conversion. Narrowing to the host's smaller integer types (the resolver's range-checked case) is not built and
stays counted.
