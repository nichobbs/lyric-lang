# dotnet Std.HttpServer h2: drain in-flight responses on peer half-close (#8683)

The h2 connection task treated the reader's end-of-input marker as an
immediate close, so a client that sent its request and then half-closed its
write side lost a response still being produced. The marker now starts a
drain (`H2ConnState.draining`, `h2BeginDrain`): nothing more is read, but
`h2Cycle` keeps running until `exchanges` is empty (every dispatched stream
finished or aborted), then the connection closes. The drain is bounded by the
connection idle timeout (`LYRIC_HTTP_IDLE_TIMEOUT_MS`) through a watchdog task
(`h2DrainWatchdog`), so a handler that never responds cannot hold the
connection open. A transport failure takes the same path; writes to a dead
socket close the connection through `h2WriteOrClose`.

Test: `scripts/ci/h2-half-close-client.py` (raw TLS h2 client that sends one
request, shuts down its write side with a FIN, then reads) runs against the
`/slow` route from `scripts/ci/dotnet-h2-scheduler-smoke.sh`. The optional
timing-assertion scaling from the issue was not needed (no CI noise seen) and is
not done.
