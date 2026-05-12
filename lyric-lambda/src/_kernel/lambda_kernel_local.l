/// Lambda.Kernel.Runtime (local) — lightweight local test server for Lambda development.
///
/// Accepts POST /2015-03-31/functions/function/invocations on localhost:{localPort}
/// with a raw Lambda event JSON body and returns the Lambda response JSON.
/// This is the same interface as:
///   aws lambda invoke --endpoint-url http://localhost:9000 ...
///   sam local invoke --event event.json
///
/// The dispatch logic is identical to the aws kernel: event source detection,
/// router forwarding for HTTP events, and handler reflection for custom events.
/// The only difference is the transport: instead of polling the Lambda Runtime
/// API over HTTP, the server accepts one invocation per HTTP request and
/// responds synchronously with the handler's result.
///
/// A synthetic LambdaContext is constructed for each request:
///   functionName       = "local-function"
///   functionVersion    = "$LATEST"
///   invokedFunctionArn = "arn:aws:lambda:us-east-1:000000000000:function:local-function"
///   memoryLimitInMb    = 512
///   requestId          = random UUID per request
///   logGroupName       = "/aws/lambda/local-function"
///   logStreamName      = "local"
///   remainingTimeMs    = 30000  (30-second default; override with LYRIC_LOCAL_TIMEOUT_MS)
///
/// Enabled only when the "local" feature flag is active.
/// Typical usage: set features = ["local"] in lyric.toml during development,
/// then switch to features = ["aws"] for production builds.
///
/// See docs/35-lambda-library.md §Local development.

@cfg(feature = "local")
package Lambda.Kernel.Runtime

import Lambda
import Web

/// Start the local Lambda test HTTP server.
/// Listens at localhost:{localPort} indefinitely.
/// Each POST to /2015-03-31/functions/function/invocations is processed
/// synchronously: the handler runs, the result is serialised, and the
/// HTTP response is sent before accepting the next request.
@axiom("Lightweight single-threaded HTTP server for local Lambda event testing")
extern package Lambda.LocalServer {
  pub func serve(
    app:       Lambda.LambdaApp,
    localPort: Int
  ): Unit
}
