# 2026-11-17: the builder types host call chains from the host's metadata (D444)

A host call on a result no `extern type` names (`m.entrySet().iterator()`) is typed by the builder from the host's metadata instead of staying counted: `openHostChainTy` gives the open call or property read the host class its members return, `buildHostMethodOnChain` builds the extern call, `erasedHostKind` converts a host `Object`, an unapplied host generic and an `Object` array to the language's erased generic types with `CvFromHost`, and a `JString` value is its own receiver. The checker is unchanged. `tir-builder-shapes-e2e.sh` builds and runs a JVM chain. Docs/70 status updated.

Follow-up: a chain result the checker maps to a Lyric type (a host array as a slice, a string, a boxed number, a task, `Object`) is not typed as the host class (`isPlainHostResult`); `tir-builder-shapes-e2e.sh` gains `jvm_host_array_result`, which found the `local-type` I0003 the library census reported on the first version.
