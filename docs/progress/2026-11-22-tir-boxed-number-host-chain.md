# TIR builder: a boxed number a host chain returns keeps its host class (D750)

`Integer.valueOf(n).intValue()`-style chains on the JVM build: the untyped inner host call keeps the box class and the member that follows is the box's own. `auto_ffi_jvm_self_test` builds 67 of 70 bodies with the fixture jar. Self-test: `tir_build_self_test.l`.
