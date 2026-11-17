# `Std.TcpHost` on the JVM, a connect timeout, and `HttpError.Timeout` on every target (#9042, #9067, D611, D612)

`Std.TcpHost` now has a JVM kernel (`_kernel_jvm/tcp_host.l`: `java.net.Socket`,
`ServerSocket`, `SSLSocket`; the dotnet surface, including server TLS with ALPN
and mTLS), so programs that listen or connect over TCP build and run on
`--target jvm` instead of failing with `J002`. `hostConnect` takes a connect
timeout on dotnet, the JVM and native (`0` = the OS limit); callers in
`lyric-ws`, `lyric-web`, the native self-tests and the stdlib tests pass `0`.

`Std.Http` reports a send that ended at its token's deadline as
`HttpError.Timeout(url, durationMs)` on every target, through
`HostHttp.hostTimeoutMessage()` and one classifier in `std/http.l`. The JVM
holds the report until `isCancelled(token)` is true (the early-fire race) and
bounds the body read by the deadline with a watchdog; dotnet maps a cancelled
token to the timeout; native keeps D605's behaviour. See D611 and D612.

Verified with `lyric-stdlib/tests/tcp_host_tests.l` (new, dotnet and JVM),
`tcp_host_tls_tests.l` (now dotnet and JVM), `http_timeout_tests.l` (new,
dotnet and JVM: 100 sends with a 25 ms deadline all `Timeout` with a cancelled
token, a stalled body, a refused connection stays `ConnectionFailed`), and
`http_timeout_native_tests.l` (asserts the `Timeout` variant).

Open: the dotnet token cannot tell a deadline from `cancelSource`, so an
explicit cancel is also `Timeout` there; `lyric-ecosystem` `net`/`redis`/
ActiveMQ can drop their own JVM socket kernels and `mq-sqs`/`storage-*` can
drop their message matching.
