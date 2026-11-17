# D612 - `Std.Http` reports a deadline expiry as `HttpError.Timeout` on every target (#9067)

**Status:** shipped.

## Context

`HttpError.Timeout` existed and nothing produced it: every transport failure,
timeouts included, was `ConnectionFailed(url, message)`, so a caller had to match
message text to tell "may have been applied" (a timeout) from "was not" (a
refused connection). On the JVM the only evidence of a timeout, the caller's
token, was unreliable: the JDK request timer is armed from the time remaining,
the token compares `System.nanoTime()` lazily, and the timer could fire a few
microseconds first (119 of 400 sends in the repro came back with the token not
yet cancelled). The JDK request timeout also ends at the response headers, so a
server that sent headers and stalled held a call past its deadline.

## Decision

1. **One text, one place.** Every `Std.HttpHost` kernel exposes
   `hostTimeoutMessage()` (`"request timed out"`, native's existing text) and
   reports a send ended by its deadline with exactly that failure text.
   `Std.Http.sendFailure` is the only place a kernel failure becomes an
   `HttpError`: that text is `Timeout(url, durationMs)` (the time the send ran),
   anything else is `ConnectionFailed(url, message)`.
2. **JVM.** A failure under a token with a deadline (and no explicit cancel) that
   is an `HttpTimeoutException`, `HttpConnectTimeoutException`, a "timed out" or
   cancellation message, or the body watchdog's text, is the timeout. The report
   waits until the monotonic clock has reached the deadline, so
   `isCancelled(token)` is true when it returns. The wait applies only when the
   deadline is at most a second away. The body read (`doSend`) runs under a
   watchdog on a virtual thread that closes the stream at the deadline and is
   interrupted when the read finishes.
3. **dotnet.** A send that fails while its token is cancelled is the timeout. The
   BCL does not say whether a token was cancelled by its timer or by
   `cancelSource`, so both are `Timeout` there; JVM and native keep an explicit
   `cancelSource` as `ConnectionFailed` naming the cancellation (a cooperative
   check on the JVM, a wake-up on native, D605). This difference is documented on
   `sendWithCancelAsync`; closing it needs the deadline carried by the token on
   dotnet (tracked in the issue draft in the progress note).
4. **native** already produced the text and the early-report guarantee (D605);
   D605's "`HttpError.Timeout` stays unproduced until #9067" is superseded.
5. **wasm module** kernel does not consult tokens and so never reports a timeout.

## Consequences

- Libraries can branch on `HttpError.Timeout` instead of matching text
  (`mq-sqs`'s `isTimeoutCause`, `storage-s3`, `storage-azure-blob`).
- Callers that matched `ConnectionFailed(_, "request timed out")` on native or
  the JVM must match `Timeout`.
