# Native: `Std.Http` honours its cancellation token; the conformance suites build for native (#9090)

**What shipped**

- `Std.Http` on `--target native` runs a send within its `CancellationToken`'s
  limits: the deadline covers the name lookup, connect, TLS handshake, request
  write and response read, over HTTP and HTTPS; `cancelSource` from another
  thread ends the send at once. A deadline is `ConnectionFailed(url, "request
  timed out")` with the token already cancelled; a refused connection is not a
  timeout (D605). Before, the token was ignored and a request to a silent
  server never returned.
- lyric-rt: bounded socket and TLS operations (`lyric_sock_connect_bounded`,
  `lyric_sock_read_bytes_bounded`, `lyric_sock_write_bytes_bounded`,
  `lyric_tls_client_connect_bounded`, `lyric_tls_read_bytes_bounded`,
  `lyric_tls_write_bytes_bounded`) and cancellation wake-ups
  (`lyric_cancel_wake_register`/`_unregister`/`_signal`), on POSIX; written
  for Windows and not compiled there; stubs on wasm32.
- `Std.TcpHost` (native): `hostConnectBounded`,
  `hostUpgradeClientTlsBounded`, `hostReadBounded`, `hostWriteBounded`,
  `WakePipe`, `BoundedError`. `hostUpgradeClientTls` reports a socket timeout
  during the handshake as "TLS handshake: timed out".
- A Unix-socket `HttpClient` on native is built and fails each request with a
  typed error; it used to panic at construction.
- `lyric-conformance`: the `Testing.Conformance.*` suites as their own
  package, on `dotnet`, the JVM and native (D604). `lyric-testing` keeps the
  mocks.
- `lyric-storage` and `lyric-jobs` build and work on native. `lyric-storage`
  reaches the host through `Storage.Port` (`Result`s on every target);
  `lyric-jobs` gets its clock, sleep and ids from `Jobs.Kernel.Native`.
- `lyric-db`, `lyric-mail` (`targets = ["dotnet", "jvm"]`) and
  `lyric-testing` (`["dotnet"]`) declare their targets, so a native build
  fails with `F0054`/`F0055`.

**Tests**

- `lyric-rt/test/lyric_tls_test.c`: bounded connect (address, name, refused,
  unresolvable, expired, interrupted, and on Linux a connect the peer never
  answers), bounded read and write, the wake registry, a stalled TLS
  handshake, a TLS round trip and a late TLS answer. `make -C lyric-rt test`,
  `test-asan`.
- `lyric-stdlib/tests/http_timeout_native_tests.l` (21 cases) and
  `lyric-stdlib/tests/tcp_host_bounded_native_tests.l` (7 cases), in
  `scripts/ci/native-backend-self-tests.sh` and
  `scripts/ci/native-platform-tests.sh`.
- `lyric-conformance/tests/conformance_tests.l` (8 cases), run by
  `scripts/ci/testing-tests.sh` on dotnet; it also passes on the JVM and on
  native.

**Not done**

- No `lyric test --manifest --target native` exists yet, so the libraries'
  native runs are not in CI.
- The Windows twins are uncompiled; the dotnet `Std.TcpHost` has no bounded
  operations; `HttpError.Timeout` is still not produced (#9067).
- `lyric-search` wraps its send in `try`, so it does not run on native;
  library aspects cannot be instantiated from a native project build
  (`A0045`, #3498).
