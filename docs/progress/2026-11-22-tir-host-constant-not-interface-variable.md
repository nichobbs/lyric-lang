# TIR builder: a static constant of a host class is its own member (D774)

`ByteT.MaxValue` and `Char.MaxValue` build: a candidate whose result is an interface's unbound type variable (`IMinMaxValue<T>`) no longer hides the class's own constant. Clears `auto_ffi_self_test` 406 and 437. Self-test: `tir_build_self_test.l`.
