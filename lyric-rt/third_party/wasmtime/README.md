The C headers of the wasmtime 49.0.3 C API, copied unchanged from
`wasmtime-v49.0.3-x86_64-linux-c-api.tar.xz` (`include/`, without
`doc-wasm.h` and the C++ `.hh` wrappers), under the Apache License 2.0 with
the LLVM exception (`LICENSE`).

`src/lyric_wasmhost.c` compiles against them for the types and the function
prototypes only; it loads `libwasmtime` at run time with `dlopen`, so neither
`lyric_rt.a` nor `liblyric_wasmhost` links against wasmtime.  Upgrading
wasmtime means replacing these headers and the pins in
`scripts/ci/fetch-wasmtime-capi.sh` together.
