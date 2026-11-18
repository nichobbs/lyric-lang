# D431 - A host member's erased Object result on a generic host class applied to type parameters (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444 and D445. The checker is unchanged and the language is unchanged.

## Context

`value = m.get(key)` in the JVM kernel's `tryGetValue[K, V](m: in Map[K, V], ..)`, where `Map[K, V]` is `extern type Map[K, V] = "java.util.HashMap"`, has no recorded type: the checker types the host's erased `Object` result as the class's instantiation, and an instantiation at type parameters gives it nothing to name. D445 types a host `Object` result only for a non-generic host class, so the call stayed counted ("the checker gave no usable type").

## Decision

`hostChainResult` also types a host member's erased `Object` result as the host `Object` when the host class's type arguments are all type parameters of the function being built (`allTypeParams`), the host's `Object` being exactly what it returns. Where the value is used at `V`, `erasedHostKind` already converts the host `Object` to a type parameter with `CvFromHost`. A concrete instantiation is still the checker's (`hostResultIsCallType`).

## Results

`Std.CollectionsHost::tryGetValue` builds (0 I0003). `tir-builder-shapes-e2e.sh` gains `jvm_host_generic_result`. Still counted: `Std.Collections::mapEntries`, whose `MapEntry(key = k, value = v)` inside the lambda passed to `dictForEachEntry` has no type because the checker records none for a generic record construction whose type arguments come from lambda parameters inferred through a generic callee; that is not a host call and is left for the generic construction work.
