# lyric-web (dotnet) dispatches each request on its own task (#7997)

`Web.serve`, `Web.serveStreaming` (and so `start`/`startStreaming`) and
`Web.serveTls` ran each handler inline on the accept loop, so one long or
streaming handler stalled every other request. The loops now pull a context
and hand it to `Web.Kernel.Runtime.spawnRequestJob`, which runs a
`Web.RequestJob` (`PlainRequestJob` / `TlsRequestJob`) on a thread-pool task.

- Per-request `Bug` isolation (#5261, #6222) moved into the job, so one failing
  request still cannot stop the listener. `serveTls` gains the same isolation
  (a handler `Bug` previously stopped its listener); only `nextContext`
  failing remains fatal.
- Concurrency is bounded by the transport's existing connection cap
  (`LYRIC_HTTP_MAX_CONNECTIONS`, #6071): each in-flight request holds a
  connection permit, so no second cap is added.
- The job is an interface, not a closure, because a captured closure value
  cannot be invoked from inside another closure on this target (see
  `startWorkerLoop`).
- Regression: `tests/concurrent_dispatch_tests.l` blocks a handler and asserts
  another request completes while it is still in flight; it fails on the
  previous sequential loop.
- JVM is unchanged: Undertow already dispatches on worker threads.
- `tests/serve_tls_tests.l` adds the same blocked-handler regression over
  `Web.serveTls` (dotnet); it fails when `serveTls` dispatches inline.
