# docs/70 phase 3a: the erased Object result of a generic host class applied to type parameters (D431)

`m.get(key)` on a `java.util.HashMap` extern type applied to the function's own type parameters (the JVM kernel's `tryGetValue`) builds: the builder types the host's `Object` result and converts it to the type parameter with `CvFromHost`. `tir-builder-shapes-e2e.sh` gains `jvm_host_generic_result`.
