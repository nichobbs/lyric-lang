# docs/70 phase 3a: a slice of host Objects as the slice of a type parameter (D430)

`HashSet.toArray()` returned where `slice[T]` is declared (the JVM kernel's `setToSlice`) builds as a `CvFromHost` conversion, and the verifier accepts `CvFromHost` on a slice of a host type. `tir-builder-shapes-e2e.sh` gains `jvm_host_array_erased`; `tir_build_self_test.l` covers the conversion.
