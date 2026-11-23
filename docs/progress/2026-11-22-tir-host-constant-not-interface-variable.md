# TIR builder: a static constant of a host class is its own member (D775)

`ByteT.MaxValue` and `Char.MaxValue` build: a candidate whose result is an interface's unbound type variable (`IMinMaxValue<T>`) no longer hides the class's own constant, a constant written as a two-segment path or read at a wider settled type builds, and a host `Char` result is `Char`. Clears `auto_ffi_self_test` 406 and 437. Self-test: `tir_build_self_test.l`.
