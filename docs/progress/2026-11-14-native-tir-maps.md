# Native backend on TIR: maps and NativePtr types (docs/70 phase 4a, D520)

`Map[K, V]` over `String` and scalar keys lowers from TIR with the AST path's `LyricMap` kernel
calls (`newMap`, `add`, `containsKey`, `remove`, `count`, `m[k]`, `m[k] = v`), registered on demand
like lists. `NativePtr[T]` over scalars and raw pointers is a lowerable type, which lets the kernel
`extern func` wrappers in the bundled stdlib lower. `native-via-tir/maps.l` runs both ways and under
AddressSanitizer.
