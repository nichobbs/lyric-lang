# D430 - A slice of host Objects used as the slice of a type parameter is a CvFromHost conversion (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444. The checker is unchanged and the language is unchanged.

## Context

D445 types an untyped host array result of host objects as the slice of its element (`hostArrayAsSlice`), so `s.toArray()` on a `java.util.HashSet` has the type `slice[Object]`. The JVM kernel's `setToSlice[T](s): slice[T]` returns exactly that, and the builder counted a branch conversion it had no case for (`slice[extern java.lang.Object]` to `slice[param T]`), in every JVM program that links the collections kernel (65 of the 239 FFI and JVM self-tests, one body).

## Decision

`erasedHostKind` converts `slice[Object]` (the host's root object class) to `slice[T]` with `CvFromHost`, the way it already converts a host `Object` to `T` and the raw host array to `slice[T]`: the host's erasure gives them one representation. `Lyric.Tir.Verify` accepts `CvFromHost` on a slice of a host type as well as on a host type; any other operand is still I0003.

## Results

`Std.CollectionsHost::setToSlice` builds. `tir-builder-shapes-e2e.sh` gains `jvm_host_array_erased` (built with `--target jvm --verify-ir`), and `tir_build_self_test.l` covers the conversion and two cases that must not convert. Still unbuilt in the same closure: `Std.CollectionsHost::tryGetValue` (the checker records no type for `m.get(key)` on the erased `Map[K, V]`) and `Std.Collections::mapEntries` (the lambda passed to `dictForEachEntry`).
