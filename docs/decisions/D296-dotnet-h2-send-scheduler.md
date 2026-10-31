# D296 - dotnet `Std.HttpServer` h2: connection-task send scheduler with interleaved streams and incremental chunked DATA (#6107)

**Status:** shipped (dotnet; the JVM Undertow path and native are unchanged)

## Context

The dotnet h2 server (docs/61 §6.4, phase 4.4) drove each request/response
strictly in turn on the connection task: it dispatched one request, blocked on
its `done` semaphore, serialized the response, and only then read further
frames. That had three consequences recorded in #6107: head-of-line blocking
across multiplexed streams, response bodies bounded by a bounded
`pumpForWindow` read pump, and h2 chunked responses buffered until
`endChunkedResponse`.

## Decision

1. **Three parties, one FSM owner.** The connection task alone feeds the
   `H2Conn` FSM, HPACK-encodes and writes frames. A per-connection **reader
   task** only moves socket reads (copied, bounded by `h2InboundCredits`) into
   an inbound queue. **Handlers** (the puller side) never touch the wire for h2.
2. **One wake signal.** The reader and handlers both release a single `wake`
   semaphore. Handlers publish through `H2Link.outbox` (a notice per change)
   and the per-stream `H2Exchange` (`status`, `contentType`, `extra`, a queue of
   body `chunks`, `chunked`, `started`, `ended`, `aborted`).
3. **Scheduler.** Each wake runs `h2Cycle`: drain inbound into the FSM,
   dispatch completed requests without waiting (`dispatchH2Stream` no longer
   blocks), register published responses, then repeat `h2SendPass` while any
   stream progresses. A pass writes at most one frame per in-flight stream,
   bounded by the connection and stream send windows, so DATA from concurrent
   streams interleaves. A peer `WINDOW_UPDATE` is ordinary input that wakes the
   task; `pumpForWindow` and `sendH2Body` are gone, so a body of any size is
   delivered as window is granted.
4. **Incremental chunked streaming.** `beginChunkedResponse` publishes the head
   (HEADERS are sent at the next cycle, with no `content-length`),
   `streamWriteChunk` queues a chunk and `endChunkedResponse` ends the stream;
   END_STREAM rides the final DATA frame when the body is already complete, and
   is an empty DATA frame otherwise.
5. **Backpressure and abort.** `streamWriteChunk` blocks once
   `h2StreamChunkCredits` (32) chunks are queued ahead of the scheduler. A
   stream the peer resets (`H2PeerReset`/`H2StreamErr`), or a connection that
   closes (`h2Teardown`), marks its exchanges `aborted` and wakes a blocked
   writer, whose write returns `Err`. A handler that publishes after teardown
   aborts its own exchange (publish, then re-check `link.closed`), so none can
   block on a dead connection.
6. **Unchanged.** HTTP/1.1, TLS, request-body caps, `413` rejection, and the
   `HttpContext`/`respond*`/chunked public surface. An h2 connection now holds
   two threadpool threads (reader and connection task).

## Verification

`http_server_dotnet_tests.l`: a slow handler does not hold up another stream,
concurrent 1.5 MB, 300 KB and 1 KB bodies arrive intact, and 200 x 16 KB chunks
stream through the credit and window; all 29 earlier cases stay green. The curl
smoke (`scripts/ci/dotnet-h2-scheduler-smoke.sh` against `dotnet_h2_smoke.l`)
checks concurrency, incremental chunk delivery and reset abort with an
independent client.

## Not done

A fully async transport (no blocking reader thread per connection) remains a
larger rework. EOF from the peer closes the connection without draining
responses still being produced.
