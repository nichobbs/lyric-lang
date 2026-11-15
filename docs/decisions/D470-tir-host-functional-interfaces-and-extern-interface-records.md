# D470 - A function value passes for a host functional interface, and a record upcasts to an extern interface it implements (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

D468 left six JVM "an extern call no host overload fits" sites: `Thread.new({ -> ... })` (a Lyric lambda for `java.lang.Runnable`) and `JThread.startVirtualThread(ScopeJob(...))` (a Lyric record whose `impl JRunnable for ScopeJob` implements an extern interface, docs/51, passed as that interface). The checker accepts both; the builder's overload scoring had no conversion for either.

## Decision

- `hostBoxKind`: a value of function type `TFunc` passed for any host type that is not `object` or a host array is `CvBoxToHost(host)`; the operand keeps its function type and the host adapts it (a delegate on dotnet, a functional interface on the JVM). It ranks with the other boxing conversions, below every widening and upcast. It excludes the host's value classes (`String`, `CharSequence`, boxed numbers and characters) and arrays: `Thread(String)` would otherwise make `Thread.new({ -> ... })` ambiguous with `Thread(Runnable)`, which the stage-2 census showed.
- `hostUpcastKind`: a value of a Lyric record, union or opaque type passed for an extern interface that the checker recorded an `impl` of (`SymbolTable.impls`, whose interface symbol names an extern type whose host name is the parameter's) is `CvBoxToHost(host)`.
- No new `ConvKind`: `CvBoxToHost` is already "a Lyric value into a host type" and the operand's type says which adaptation a backend performs.

## Not covered

Whether a given host parameter really is a functional interface is the checker's and the host metadata's judgment, as it is for every host argument; the builder records the conversion the checker accepted.
