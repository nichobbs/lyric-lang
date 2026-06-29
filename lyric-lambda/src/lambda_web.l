//! Lambda (web) — lyric-web Router integration for LambdaApp.
//!
//! Compiled only when the `web` feature is active.  Contributes to the
//! `Lambda` package (multi-file package alongside lambda.l).
//!
//! Provides withRouter(), which registers a Web.Router with the Lambda kernel
//! via Lambda.Kernel.WebBridge and stores an opaque LambdaRouter token in the
//! LambdaApp.  This keeps Web types out of LambdaApp's contract metadata so
//! consumers without the `web` feature compile without a lyric-web dependency.
@cfg(feature = "web")
package Lambda

import Std.Core
import Web
import Lambda.Kernel.WebBridge as WebBridge

/// Attach a lyric-web Router for API Gateway and ALB HTTP events.
/// API Gateway v1 (REST API), v2 (HTTP API), and ALB events are mapped
/// to the router's method + path and dispatched through the same mechanism
/// as Web.start().  CORS config is read from the Web.Cors config block.
/// Cannot be combined with withStreamingHandler in the same LambdaApp.
/// Requires the `web` feature to be active in the consumer's lyric.toml.
@stable(since = "0.1")
pub func withRouter(app: in LambdaApp, router: in Router): LambdaApp {
  val lr = WebBridge.createRouterToken(router)
  return LambdaApp(
    httpRouter = Some(lr),
    streamingHandler = app.streamingHandler,
    eventHandlers = app.eventHandlers,
    authorizerHandlers = app.authorizerHandlers,
    directHandlers = app.directHandlers
  )
}
