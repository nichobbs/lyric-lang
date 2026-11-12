# 2026-11-12 - Std.Http: binary request bodies, response header names; Std.HttpServer: request body bytes

A pure-Lyric S3 client (lyric-ecosystem `storage-s3`, docs/71) has to PUT arbitrary bytes and read back `x-amz-meta-*` headers whose names it does not know in advance. `Std.Http` could do neither: a request body was a `String` re-encoded as UTF-8, and a response header could only be looked up by name.

**`Std.Http`**

- `withBytesBody(request, contentType, bytes: in slice[Byte]): Result[HttpRequest, HttpError]` attaches a body that is sent byte for byte, with `Content-Type` exactly as written (no `charset` appended) and `Content-Length` the slice's length. An empty slice is a zero-length body. An empty content type, or one with a control character, is `InvalidHeader` naming `Content-Type`. The request keeps a reference to the slice, as it keeps a text body; `retry` rebuilds a fresh host request from it for each attempt.
- `HttpResponse.headerNames(): slice[String]` lists every response header name once (case as received, lowercase over HTTP/2).

Kernels, one `hostWithBytesBody` and one `hostResponseHeaderNames` each:

- dotnet (`_kernel/http_host.l`): `ByteArrayContent`, with the content type added to its headers unparsed; names read from `HttpHeaders.ToString()`, because enumerating the collection needs a `KeyValuePair<string, IEnumerable<string>>` MemberRef auto-FFI cannot name.
- JVM (`_kernel_jvm/http_host.l`): the request record's body is now `slice[Byte]` (a text body is encoded when attached) and is published with `BodyPublishers.ofByteArray`; the Unix-socket path hands the same bytes to `Std.HttpClientWire`. Names come from `HttpHeaders.map().keySet()`.
- native (`_kernel_native/http_host.l`): the request record's body is `slice[Byte]`, written after the head unchanged.
- wasm module shape (`_kernel_wasm_module/http_host.l`, `wasm/glue_runtime.js`): the `std.http.fetch` import gains an eighth argument, `bodyIsBase64`; a byte body crosses as base64 and the built-in import gives `fetch` a `Uint8Array`. A replacement import that ignores the argument behaves as before for text bodies.

**`Std.HttpServer`**

- `requestBodyBytes(c): slice[Byte]` returns the request body as received, on dotnet, JVM and native. `requestBody` stays the UTF-8 text view. The JVM kernel kept the admitted body as a UTF-8-decoded `String`, which replaced every malformed sequence; it now keeps it as an ISO-8859-1 carrier string (one char per byte) and decodes on `requestBody`.
- JVM `requestPath` returned `URI.getPath()`, the decoded path, while the dotnet and native kernels return the raw request target. It now returns `getRawPath()`, so a server that verifies a signature over the path, or decodes segments itself as `lyric-web` does, sees the same string on every target.

**Verification**

- `lyric-stdlib/tests/http_bytes_body_tests.l` (new, in CI on dotnet and JVM): against a live `Std.HttpServer` echo listener, all 256 byte values through `sendAsync` and `HttpClient.send`, an empty body, a byte body replacing a text body, a signed-request header set (`Authorization`, `x-amz-date`, `x-amz-content-sha256`, `x-amz-meta-*`) with `Host` equal to the URL authority and a percent-encoded path delivered as written, HEAD and DELETE, `headerNames`, `retry` replaying a byte body after a refused first attempt, and the `InvalidHeader` cases. 7 pass on `--target dotnet` and `--target jvm`.
- native: `llvm_http_client_self_test.l` item U sends a byte body holding NUL, 0xFF, CR, LF and lone UTF-8 lead and continuation bytes, and the server thread checks the raw request tail (17 pass, under AddressSanitizer).
- wasm module: `llvm_wasm32_module_self_test.l` checks that the byte body reaches `fetch` as a `Uint8Array`, that a text body still arrives as a string, and `headerNames` (33 pass).
- Existing suites unchanged: `http_tests.l`, `http_async_tests.l`, `http_server_dotnet_tests.l`, `http_async_concurrency_tests.l`, `http_version_tests.l` on dotnet; `http_async_tests.l`, `http_server_jvm_tests.l`, `http_unix_socket_jvm_tests.l`, `http_client_wire_tests.l` on JVM; `lyric-search` and `lyric-otel` on both targets.

**Found, not changed here**

- `Std.HttpServer` has no way to answer a HEAD request correctly. The dotnet and native kernels write the body bytes passed to `respond*` after the head whatever the method, so the only safe HEAD response is an empty body, which reports `Content-Length: 0` instead of the length a GET would have. The JVM kernel throws from the body write when the body is non-empty. The HTTP/2 path frames the body the same way. A handler therefore cannot report an entity's size to a HEAD.
- JVM codegen: an empty slice literal as the value of a `catch` arm (`return try { f() } catch Bug as _ { [] }` in a function returning `slice[Byte]`) is emitted as an `ArrayList`, and the class fails verification (`'java/util/ArrayList' is not assignable to '[Ljava/lang/Object;'`). Binding the literal to a typed `val` first avoids it.
- JVM codegen: in a library package, a `slice[Byte]` that came from a stdlib call (`encodeUtf8(...)`, a `tryDecodeBase64` match payload) is a `byte[]`, and passing it to another Lyric function's `in slice[Byte]` parameter is emitted without the boxing conversion, so the class fails verification (`'[B' is not assignable to '[Ljava/lang/Object;'`). The same call from a `@test_module` verifies. Related to #7806.
