# JVM: Unix-domain-socket HTTP clients (#8560)

`Std.Http.clientWithUnixSocket` and `HttpClientBuilder.withUnixSocket` now work
on `--target jvm` (D279). Before, the JVM kernel panicked because
`java.net.http.HttpClient` cannot dial a Unix socket.

- `lyric-stdlib/std/http_client_wire.l`: `Std.HttpClientWire`, a sans-IO
  HTTP/1.1 client codec (request serializer, response parser).
  `lyric-stdlib/tests/http_client_wire_tests.l` has 13 cases, run on both targets
  (including byte-at-a-time feeding).
- `lyric-stdlib/std/_kernel_jvm/http_host.l`: `HttpClientHandle` is a record;
  Unix clients use a `SocketChannel` plus `Selector` with the cancellation
  deadline, the codec, and redirect following.
- `lyric-stdlib/tests/http_unix_socket_jvm_tests.l`: six cases against an
  in-process Unix-socket server (GET, chunked, POST body, redirect and
  no-redirect, missing socket, silent daemon under a deadline).
- `lyric-docker`: the Unix-socket `tryMakeDockerClient` test is no longer
  dotnet-only; the `docker` JVM suite stays in `scripts/ci/jvm-ecosystem-suites.sh`.
- `Std.Http`'s "TLS with a Unix socket" message now names both targets' reasons.

Verified locally: `lyric test --target jvm` for the new tests, `http_tests.l`, and
`--manifest lyric-docker/lyric.toml` (100 of 100).
