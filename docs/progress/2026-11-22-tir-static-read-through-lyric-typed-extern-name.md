# TIR builder: a static member read through the extern type name of a host class that has a Lyric type (D772)

`ByteT.MaxValue` builds: `hostChainReceiver` takes the host class an `extern type` names when the checker typed the name as the Lyric primitive. Clears `auto_ffi_self_test` 406. Self-test: `tir_build_self_test.l`.
