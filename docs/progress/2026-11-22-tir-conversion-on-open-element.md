# TIR builder: a numeric conversion on any expression the builder types as a primitive (D773)

`copied[0].toInt()` on an element of an untyped host array local builds: `buildConvMethodOnOpenPrim` reads the receiver's type with `exprOrOpenTy`, not only for host chains. Clears `auto_ffi_self_test` 341. Self-test: `tir_build_self_test.l`.
