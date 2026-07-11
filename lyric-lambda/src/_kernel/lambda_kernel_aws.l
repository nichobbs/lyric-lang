//! Lambda.Kernel.Runtime (aws) — .NET custom runtime loop.
//!
//! Used to declare `extern package Amazon.Lambda.RuntimeSupport` and
//! delegate the entire invocation loop to it. No such NuGet-backed adapter
//! was ever written to back that declaration — the AWS custom runtime
//! protocol is plain HTTP GET/POST against `$AWS_LAMBDA_RUNTIME_API` and
//! needs no FFI at all. The real implementation now lives in
//! `Lambda.Dispatch` (`src/dispatch.l`), shared with the `local` feature
//! variant since the dispatch logic (event-source detection, JSON
//! marshalling, `Lambda.Direct` handler resolution) is identical between
//! them — only the transport differs. See that file's header comment for
//! exactly what is and is not implemented.
//!
//! Enabled only when the "aws" feature flag is active.
//! See docs/35-lambda-library.md §Kernel, docs/14-native-stdlib-plan.md.
@cfg(feature = "aws")
package Lambda.Kernel.Runtime

import Lambda
import Lambda.Dispatch as Dispatch

/// Start the custom runtime invocation loop against
/// `$AWS_LAMBDA_RUNTIME_API`. Blocks until the runtime API becomes
/// unreachable, at which point the process exits non-zero (AWS recycles
/// the execution environment). `localPort` is accepted but unused — it
/// exists only to keep `serve()`'s signature uniform across every feature
/// variant of this package.
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  Dispatch.runAwsCustomRuntimeLoop(app)
}
