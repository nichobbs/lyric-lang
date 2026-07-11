//! Lambda.Kernel.Runtime (local) — lightweight local test server for Lambda development.
//!
//! Used to declare `extern package Lambda.LocalServer` and delegate to it.
//! No such adapter was ever written. The real implementation now lives in
//! `Lambda.Dispatch` (`src/dispatch.l`), shared with the `aws` feature
//! variant — "the dispatch logic is identical to the aws kernel", per this
//! file's original header comment; only the transport differs (a
//! synchronous `Std.HttpServer` accept loop here, HTTP long-polling
//! against `$AWS_LAMBDA_RUNTIME_API` there).
//!
//! Accepts one request per invocation on `localhost:{localPort}` with a
//! raw Lambda event JSON body and returns the Lambda response JSON — the
//! same interface as `aws lambda invoke --endpoint-url http://localhost:9000`
//! / `sam local invoke --event event.json`.
//!
//! A synthetic LambdaContext is constructed for each request (see
//! `Lambda.Dispatch.buildLocalContext`):
//!   functionName       = "local-function"
//!   functionVersion    = "$LATEST"
//!   invokedFunctionArn = "arn:aws:lambda:us-east-1:000000000000:function:local-function"
//!   memoryLimitInMb    = 512
//!   requestId          = random UUID per request
//!   logGroupName       = "/aws/lambda/local-function"
//!   logStreamName      = "local"
//!   remainingTimeMs    = 30000  (30-second default; override with LYRIC_LOCAL_TIMEOUT_MS)
//!
//! Enabled only when the "local" feature flag is active.
//! See docs/35-lambda-library.md §Local development.
@cfg(feature = "local")
package Lambda.Kernel.Runtime

import Lambda
import Lambda.Dispatch as Dispatch

/// Start the local Lambda test HTTP server. Listens at
/// `localhost:{localPort}` indefinitely; each request is handled
/// synchronously (one at a time) by `Lambda.Dispatch.handleOneLocalRequest`.
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  Dispatch.runLocalServer(app, localPort)
}
