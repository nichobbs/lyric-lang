# TIR builder: a host UInt32 or UInt64 result typed Long is read with CvFromHost (D771)

`UInt32T.Parse(s)` builds: the call keeps the host's `UInt32` result and `CvFromHost` gives the `Long` the checker typed. Clears the `auto_ffi_self_test` I0003 `call-result-type`. Self-test: `tir_build_self_test.l`.
