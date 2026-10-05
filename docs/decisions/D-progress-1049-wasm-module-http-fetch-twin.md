# D-progress-1049: fetch-backed Std.Http for the wasm32 module shape

**Status:** shipped (docs/35 Q-JS-008, #8117 item 7, `Std.Http` half)

## Decision

1. `--target native --triple wasm32-wasi --shape module` compiles `Std.Http` against a
   browser-host kernel twin, `lyric-stdlib/std/_kernel_wasm_module/http_host.l`, instead of
   the libcurl-style `_kernel_native/http_host.l`. The public `std/http.l` is unchanged, so
   the whole `Std.Http` API (builder, `send`/`get`/`post`/..., cancellation overloads,
   response accessors) is the same source on every target.
2. The stdlib loader gains `findStdlibSourcesNativeForShape(shape)`: for the `module` shape,
   `_kernel_wasm_module/<module>.l` wins over `_kernel_native/<module>.l` by basename (the
   `_kernel_jvm/` model). Other shapes and `findStdlibSourcesNative()` are unchanged.
3. The twin talks to the host through one `@wasmImport("std.http", promise)` extern,
   `fetch`. The request is flattened to scalar arguments and the response comes back as one
   String (`ok`, status, header lines, blank line, base64 body; or `error` and a message).
   Transport failures are `error` replies, never rejected promises, so they surface as a
   typed `HttpError.ConnectionFailed` instead of panicking the awaiting code.
4. The generated glue ships a default `std.http.fetch` over the host's global `fetch`
   (streaming the body, capped at 10 MiB). `instantiate(..., { imports: { 'std.http':
   { fetch } } })` replaces it (test doubles, authentication). The `.d.ts` types the
   `std.http` module as optional. Imports declared by stdlib units, not only the program's
   own, now reach the glue (`collectWasmExportsOfShaped`).
5. Unsupported options fail loudly at request time, never silently:
   - TLS configuration (`withCaCertificate`, `withExclusiveCaCertificate`,
     `withClientIdentity`, `withMinTlsVersion`, `withInsecureSkipVerify`):
     `tlsConfigSupported()` is `false`, `build()` stays infallible, and every request through
     such a client fails with `ConnectionFailed` naming the gap. A browser owns certificate
     verification; ignoring a security option would silently change a caller's policy.
   - Unix domain sockets: same failure.
6. Disclosed divergences: HTTP version pins are accepted without effect and
   `negotiatedVersion` reports HTTP/1.1 (`fetch` hides the negotiated version); the redirect
   hop cap is the host's; with redirects off a browser hides the redirect response, which is
   reported as an error; cancellation tokens are accepted and an in-flight `fetch` is not
   aborted; the host decides which request headers may be set (CORS applies).

## Known limit, pre-existing

`HttpClient` is an interface with `async` methods, which the native backend cannot lower yet
(N3.2; documented in `llvm_http_client_self_test.l`). A native-built program therefore reaches
`Std.Http` through the free functions (`getAsync`, `postAsync`, `sendAsync`, ...), not through
`defaultClient()` or `HttpClientBuilder.build()`. The TLS refusal lives in `build()`, which
needs that interface, so it is covered by the shared `http.l` logic and becomes reachable on
this shape when the interface gap closes; the Unix-socket and redirect-off refusals are
exercised through `Std.HttpHost` directly.

## Not covered

`Std.File` behaviour with no preopened filesystem (an in-memory virtual filesystem in the JS
WASI shim, the next slice of #8117 item 7).
