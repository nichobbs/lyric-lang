# dotnet h2 send scheduler: interleaved streams and incremental chunked DATA (D296, #6107)

The dotnet `Std.HttpServer` h2 driver (`lyric-stdlib/std/_kernel/http_server.l`) no longer finishes one
request/response before reading the next. A per-connection reader task feeds the connection task, handlers publish
responses into a per-stream mailbox, and the connection task is the single owner of the h2 FSM and writes one frame
per in-flight stream per pass.

- A slow handler on one stream does not delay other streams on the connection.
- DATA frames of concurrent streams interleave; bodies of any size are delivered as the peer grants window.
- `beginChunkedResponse` sends HEADERS immediately, `streamWriteChunk` frames each chunk as it is written (blocking
  on a 32-chunk per-stream credit), and `endChunkedResponse` ends the stream.
- A stream reset by the peer, or a closed connection, makes the handler's next `streamWriteChunk` return `Err`.

Tests: three new cases in `http_server_dotnet_tests.l` (32 total, all green), and `scripts/ci/dotnet-h2-scheduler-smoke.sh`
in the existing curl h2 CI step (concurrency, incremental chunks, reset abort via `dotnet_h2_smoke.l`). Docs: docs/61
§6.4 updated; decision D296.
