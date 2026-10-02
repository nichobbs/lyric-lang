# lyric-rt builds for wasm32-wasi and runs its unit tests under wasmtime (docs/35 W2, slice 1)

The runtime half of phase W2 (D-progress-1028): `lyric-rt` cross-compiles to
`wasm32-wasi` with a pinned wasi-sdk, and its C unit tests run under a pinned
wasmtime in CI. The compiler half (a link recipe and per-triple archive
lookup in the native bridge, then running Lyric programs) is the next slice.

## Build

`make -C lyric-rt wasm32-wasi WASI_SDK=<wasi-sdk>` produces
`build/wasm32-wasi/lyric_rt.a` with `-Wall -Wextra -Werror`;
`make test-wasm32-wasi WASI_SDK=... WASMTIME=...` builds and runs
`lyric_rt_test` under `wasmtime run --dir=.`. wasi-sdk 24 (clang 18, the
version the other native lanes pin) and wasmtime 26.0.1 are downloaded from
their official releases and sha256-verified by
`scripts/ci/wasm32-wasi-rt-tests.sh`, which the `native-backend-self-tests`
job runs as an extra step.

## Capabilities WASI does not have

`lyric_process.c` and `lyric_tls.c` are replaced in the wasm build by
`lyric_process_unsupported.c` and `lyric_net_unsupported.c`. Every symbol the
`_kernel_native` process, TCP, TLS and HTTP-server kernels declare still
resolves, and each reports the failure its real counterpart reports when it
cannot start (a done op with `spawn_failed`, a NULL handle, `-1` with a
recorded message, `lyric_tls_available() == 0`), so a program that reaches one
sees a typed error instead of an undefined symbol at link time. `lyric_tls.c`
is the swappable seam docs/61 §7 designs, which is why the twin lives at that
boundary.

## Single-threaded runtime

On WASI `lyric_mutex_*` is a nesting-depth counter (a protected member that
calls a sibling still balances lock and unlock) and `lyric_sem_*` a plain
counter. Releasing a lock that is not held, or waiting on a semaphore nothing
can post, panics instead of hanging.

## Portability fixes found by running on WASI

- `lyric_dir_remove` strips trailing `/` before `rmdir`: POSIX accepts
  `rmdir("a/b/")`, WASI's `path_remove_directory` does not. This is a runtime
  fix on every target.
- `getentropy` backs `lyric_secure_random`, and the POSIX feature-test macros
  that gated `clock_gettime`, `nanosleep`, `setenv` and `getrandom` now also
  apply under wasi-libc.

## Tests

`lyric_rt_test.c` compiles out, under `__wasi__`, the cases that need fork,
pthreads, signals, child processes, pipes, symlinks or a pre-1970 mtime (none
exist or are representable on WASI). Temp files use a counter-suffixed name in
the preopened directory because wasi-libc has no `mkstemp`/`mkdtemp`. All
remaining cases pass under wasmtime, and the host runtime tests pass under
clang and gcc.
