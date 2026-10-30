# D278 - JVM Unix-socket HTTP, trace-root sampling, and `@query` route parameters

**Status:** shipped (#8560, #8571, #7907 in part). Extends D259 and D151.

## Context

Three open ecosystem issues needed a design choice rather than a patch:

- `java.net.http.HttpClient` has no Unix-domain-socket transport, so
  `Std.Http.clientWithUnixSocket` panicked on `--target jvm` and `lyric-docker`
  could reach the daemon only through `tcp://` (#8560).
- `OTel.Tracing.sampleRate` is drawn per call, and the issue asked whether the
  decision should be parent-based (#8571).
- `Ui.Routes` ignored the query string, and the issue proposed `@query` on a
  case field (#7907).

## Decision

1. **A client-side wire codec, not the server engine.** `Std.HttpEngine` is the
   server half of HTTP/1.1 (it parses requests and serializes responses), so
   the Unix path cannot reuse it. `Std.HttpClientWire` (`std/http_client_wire.l`)
   is its client twin: `serializeClientRequest` and `parseClientResponse` over
   bytes, with no socket. It frames `Content-Length`, `chunked` and
   read-to-end bodies, skips `1xx`, gives `HEAD`/`204`/`304` no body, and
   refuses `Transfer-Encoding` with `Content-Length`, conflicting lengths and
   unknown codings. Header injection (CR, LF, NUL) is rejected when
   serializing. Pure Lyric, so both targets run the same test corpus.
2. **The JVM kernel owns only the socket.** `HttpClientHandle` in
   `_kernel_jvm/http_host.l` becomes a record: the JDK client plus an optional
   Unix path and redirect limit. A Unix request opens a non-blocking
   `SocketChannel` over `UnixDomainSocketAddress` (JDK 16+), drives it with a
   `Selector` so a `makeCancelSourceTimeout` deadline bounds both the write and
   the read, sends `Connection: close`, reads to end of stream and hands the
   bytes to the codec. Redirects follow `Location` over the same socket
   (301/302/303 turn a non-GET into GET, 307/308 keep the method) up to the
   limit, 50 by default as in the dotnet kernel; `https://` is refused. HTTP/1.1
   only, so the `*Http11` constructors are the plain ones. TLS with a Unix
   socket stays unsupported on both targets, with a message naming each reason.
3. **Sampling is a trace-root decision today.** Every span is the root of its
   own trace (no context propagation yet, `OTel` README "Known limitations"), so
   the per-call draw is exactly the head-based root decision. Once a current
   span exists, a child inherits its parent's sampled flag and only roots draw,
   so a sampled trace never lacks spans under an unsampled one. The draw now
   comes from `Std.Random` (`randomUnit`, public so it is testable); trace and
   span ids still use `Std.SecureRandom`.
4. **`@query` is a case annotation.** A case's parameter list takes no
   annotations, so `@query(field)` or `@query(field, "name")` sits on the case.
   A query field is an `Option[T]` for a `T` a path segment can hold; absent is
   `None`, an unparsable value makes the case not match, and `routeUrl` writes
   `Some` fields after the path in field order. `Ui.Routing` gains
   `queryPresent`, `queryValue` and `withQuery`. `+` decodes as a space and a
   literal plus is written `%2B`. Diagnostic `RT007`.

## Not done

#6344 (per-request `_meta` negotiation): docs/64 §3.1 records the idea as
considered and not implemented and gives no design, and no `lyric-mcp` consumer
needs it. Left open.

#7907 keeps nested derived records, `List[T]`/`DraftRows` fields, `Date`
inputs and passing other files' declarations to the preprocessor open. Each
needs generator, runtime and host changes that are separate work.
