# Native backends for lyric-web and lyric-ws: cfg composition, module globals, kernels (#7990)

First slices of unblocking the lyric-ui desktop host on `--target native`
(docs/65 U5, #7990), which needs `lyric-web` and `lyric-ws` to build natively.

- **`@cfg` composition.** `@cfg(any(...))`, `all(...)` and `not(...)`, nested to
  any depth (`Lyric.Cfg`, a new `AACall` annotation-argument form, parser
  including the `not` keyword, formatter, grammar, docs/24 §4.1). A malformed
  composite is `F0012` and keeps the item; every operand is evaluated so a typo
  is always reported. One kernel file can now be compiled for `dotnet` and
  `native` and erased on `jvm`.
- **Module-level globals on native.** A `val` with a declared type and a
  non-literal initializer is a zero-initialised static global. The native
  bridge hoists the initializer into `__lyric_mvinit_<name>()` before type
  check and monomorphisation (generic initialisers instantiate normally);
  the codegen registers each referenced global with a guard flag and a
  synthesised `mvensure.<name>` function; every load calls it first, so an
  initializer that reads another global (across files) runs that one first
  regardless of file order, and `lyric_init_module_globals` ensures all of them
  before `main`. Loads borrow from
  the global like a local slot. Only the project's own packages hoist; a
  non-literal `val` in a bundled stdlib package still reports the old error.
  `default()` against an expected type is now the zero value on native.
- **Runtime.** `lyric_thread_spawn_detached` (the thread releases its closure
  when it ends) and `lyric_sock_peer_string`, with wasm32 stubs and C tests.
- **Native `Std.TcpHost` / `Std.HttpServer`.** `hostRemoteAddress`,
  `takeConnection` (the connection thread leaves the connection open for its
  new owner, who must `hostClose` it and shut it down: `stopListener` no longer
  tracks it) and the chunked-response API.
- **lyric-ws / lyric-web.** A `native` feature in both manifests. The RFC 6455
  server and the rate limiter are shared with `dotnet`; locks, the concurrent
  dictionary, background threads and sleep are per-target primitives in
  `_kernel/net/ws_prims.l` and `_kernel/native/ws_prims.l`.
- **Native codegen fixes found on the way.** Bare-name function resolution is
  import-aware (`toLower` on `Char` versus `String` no longer collides);
  stdlib callees reachable only as `impl` methods are seeded into the
  reachability walk; `Never` lowers as `void`; config-template expansion runs
  on the native pipeline; the `lyric-auth` algorithm check uses the `String`
  method form.
- **Native stdlib twins.** `Std.Random`, `Std.Hash` (SHA-1/256/512, MD5, HMAC
  inputs) and the `Std.Json` string encoder, which lyric-web needs.

Verification: `examples/native-web` builds with `--target native` (18
packages) and `scripts/ci/native-web-smoke.sh` (wired into CI) checks the
routes, a 404, a POST body and a WebSocket echo over a raw RFC 6455 client.
Self-tests: `cfg_self_test.l`, `cfg_gate_self_test.l`,
`llvm_project_self_test.l` (module globals), `llvm_http_server_self_test.l`
(takeConnection and chunked streaming, items N to P), `lyric-rt` C tests.

Known gaps: `Std.Json` document parsing and floats on native (#7856), JVM (tracked in #8133)
parity for the lyric-web/lyric-ws native-only seams.

Native codegen fixes found by building `lyric-ui` natively (#7990):

- A bare call to a sibling entry or func inside a protected-type body
  (`removeExpired(now, graceMs)` in `admit`) lowers to `self.removeExpired(..)`;
  the member mutex is recursive, as `Monitor` is on MSIL. Covered by
  `protected_iface_impl_self_test.l`.
- The reachability walk now seeds record methods and protected-type members of
  the project's own packages, not only free functions and `impl` methods, so a
  stdlib generic used only there (`mapKeys` in a protected entry) reaches the
  bundle.
- `r.f(args)` on a function-typed record field reads the field and calls the
  closure it holds (`record_field_closure_self_test.l`, now in the native lane).

#7864 (generic protected types, N0008) does not block `lyric-ui`: every
protected type in `lyric-ui` is non-generic and the native build passes the
N0008 pre-pass. The remaining native blocker is `Std.Task` (`makeScope`,
`scopeSpawn`, `cancelScope`, `isCancelled`), which has no `_kernel_native`
twin.
