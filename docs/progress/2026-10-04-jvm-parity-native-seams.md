# JVM parity for the native-only seams (#8133)

Decisions for each item of #8133, with what shipped.

- **Chunked streaming** (`beginChunkedResponse`, `streamWriteChunk`,
  `endChunkedResponse`) now exists in the JVM `Std.HttpServer` kernel, over the
  exchange's response body, with a runtime test in `http_server_jvm_tests.l`.
  Every target has the three helpers.
- **`takeConnection`** is a permanent difference: `com.sun.net.httpserver` does not
  expose an exchange's socket. A WebSocket upgrade on the JVM is served by Undertow
  (`Ws.Kernel.Jvm`), which `lyric-web` and `lyric-ws` already select there. Documented
  in the kernel header and in appendix B.
- **`hostRemoteAddress`** is `Std.TcpHost`, which has no JVM kernel; the JVM
  WebSocket path reads the peer address from Undertow. Not a gap.
- **lyric-web / lyric-ws shared net kernels** (`Web.Kernel.Runtime`, `Ws.Kernel.Net`)
  are compiled for `dotnet` and `native` and erased for `jvm` by design: the JVM
  keeps its Undertow kernels (`startWorkerLoop` exists there; `spawnRequestJob` and the
  accept-loop step have no JVM meaning because Undertow owns dispatch).
- **`Std.Random`, `Std.Hash`, `Std.SecureRandom`, `Std.Json`**: the public surfaces of
  the JVM and native kernels are identical (checked name for name); the JVM twins
  already existed.
- **`@cfg(any/all/not)`** is covered on the JVM (`middle_end_passes_jvm_self_test.l`)
  and MSIL (`msil_project_bridge_self_test.l`) project builds, not only by the
  evaluator tests.
- **`Std.Task` on native** shipped in #8135.
