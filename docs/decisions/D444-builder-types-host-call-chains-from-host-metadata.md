# D444 - The builder types a host call chain from the host's metadata (docs/70 phase 3a, #8613)

**Status:** shipped; extends D493 and D440. Replaces the checker-side typing of the withdrawn #9175, which changed what the checker accepts.

## Context

A host call whose result is a host class no `extern type` names (`m.entrySet()` on a `HashMap`) is left untyped by the checker: docs/01 section 2.11 leaves a host result unchecked, and that stays. A call on such a result (`m.entrySet().iterator()`) then has an untyped receiver and no recorded callee, so the whole body stayed counted ("a call the checker did not resolve", 56 self-test and 24 standard-library bodies, most of them the JVM kernels).

## Decision

The builder types the chain itself, changing nothing the checker accepts.

- `openHostChainTy` (an addition to `openHoleTy`, which types an expression the checker left open): a call or property read on a receiver whose host class is known (recorded, or itself a chain) takes the host class every instance candidate of the member returns in the host metadata, as a `TExtern` type. Candidates that disagree, a static member, a void result and a result that is not a host class stay counted.
- `buildHostMethodOnChain`: a call with no recorded callee on such a receiver is the extern call on the receiver's host class (the shape D493 added for a `String` receiver). A generic host class is left counted, since its type arguments come from a checker site a chain does not have.
- `erasedHostKind`, in `convertValue`: the host's erasure makes some host values the language's generic types, so a host `Object` used as a type parameter, a host generic class applied to type arguments, and the host's `Object` array as a slice of a type parameter convert with `CvFromHost` (representation unchanged).
- A value of the host string class (`JString`) is its own receiver for a call on it (D493 had only the language's `String`).

## Results

The JVM standard-library kernels `dictForEachEntry`, `tryGetValue`, `setToSlice` and `hostIndexOfFrom` build, and `hostCompareOrdinal`-style calls on `String` are unchanged. `tir-builder-shapes-e2e.sh` gains `jvm_host_chain` (the chain built with `--target jvm --verify-ir` and run).

## Not covered

`hostAppend`, `hostAppendChar` and `mapEntries` stay counted: the checker itself gives their `append` and `Map` calls no usable type (`<error>`), which this builder-side typing does not reach.
