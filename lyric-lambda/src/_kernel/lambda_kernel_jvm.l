//! Lambda.Kernel.Runtime (jvm) — custom-runtime HTTP polling, same protocol
//! as `aws`/`local`.
//!
//! ## Deployment-model decision (resolved; see docs/35-lambda-library.md §12
//! and the decision log)
//!
//! Two designs were live candidates for the JVM target (tracked on issue
//! #5412):
//!
//!   (a) New self-hosted JVM emitter codegen that synthesizes a
//!       host-invoked entry-point class implementing
//!       `com.amazonaws.services.lambda.runtime.RequestStreamHandler`,
//!       deployed on the AWS *managed* Java runtime (`java21`/`java17`),
//!       which reflectively instantiates that class and calls
//!       `handleRequest(...)` on it — host-calls-into-Lyric, requiring a
//!       genuinely new compiler feature with no existing analog (docs/51's
//!       `impl <ExternInterface>` only emits an `InterfaceImpl` row against
//!       an existing TypeRef on MSIL; it does not synthesize a
//!       platform-instantiated entry-point class on either target).
//!   (b) Redesign the JVM target onto the same HTTP long-polling
//!       custom-runtime protocol `Lambda.Dispatch` already implements for
//!       `aws`/`local`, deployed as a **custom runtime**
//!       (`provided.al2`/`provided.al2023`, or a container image using the
//!       `provided.al2023` base) instead of the managed `java21` runtime.
//!
//! **Decision: (b).** AWS's custom-runtime protocol (plain HTTP GET/POST
//! against `$AWS_LAMBDA_RUNTIME_API`) is defined identically regardless of
//! implementation language — it is how the .NET custom runtime already
//! works in this library, and the JVM target can poll the exact same three
//! endpoints. This needs zero new JVM-emitter codegen (no host-invoked
//! entry-point class, no reflective platform-side instantiation) and lets
//! the JVM kernel be a literal one-line call to the already-implemented,
//! already-tested `Lambda.Dispatch.runAwsCustomRuntimeLoop` — the same
//! function the `aws` (.NET) kernel calls. `Std.Http`/`Std.HttpServer` have
//! real (non-phantom) JVM kernels as of docs/59 Wave 4 (D-progress-647–650),
//! so the dispatch loop's `Std.Http` client calls work on this target with
//! no additional stdlib work — verified end to end by
//! `tests/lambda_runtime_loop_tests.l`'s mock Runtime API server, run under
//! `--target jvm --features jvm`.
//!
//! Trade-off accepted: a `provided.al2`/`provided.al2023` deployment does
//! not get the managed runtime's automatic handler-class wiring (the
//! function's Lambda configuration names the handler as
//! `<assembly>.<pkg>$LambdaHandler::handleRequest` for the managed runtime;
//! a custom runtime instead ships an executable named `bootstrap` at the
//! root of the deployment package/layer, which this JVM process's `java
//! -jar <bundled-jar>` invocation is wrapped by — the same bootstrap-script
//! packaging step the `aws` (.NET) custom runtime already requires, not a
//! new JVM-specific packaging burden). This is deliberately preferred over
//! (a): it reuses proven code instead of adding a new, nontrivial
//! host-calls-into-Lyric compiler feature whose only consumer would be this
//! one library.
//!
//! No `[maven]` dependency is needed for this feature any more — the
//! managed-runtime SDKs (`aws-lambda-java-core`/`aws-lambda-java-events`)
//! this kernel used to declare as an (unimplemented) `extern package`
//! boundary are for the `RequestStreamHandler` entry point design (a),
//! which was not chosen; `Lambda.Dispatch` is pure Lyric over `Std.Http`.
//!
//! Enabled only when the "jvm" feature flag is active.
//! See docs/35-lambda-library.md §8.4/§12, docs/18-jvm-emission.md, D064,
//! and the JVM decision recorded in docs/03-decision-log.md.
@cfg(feature = "jvm")
package Lambda.Kernel.Runtime

import Lambda
import Lambda.Dispatch as Dispatch

/// Start the custom runtime invocation loop against
/// `$AWS_LAMBDA_RUNTIME_API`, identical to the `aws` (.NET) kernel — see
/// `Lambda.Dispatch.runAwsCustomRuntimeLoop`. Blocks until the runtime API
/// becomes unreachable, at which point the process exits non-zero (AWS
/// recycles the execution environment). `localPort` is accepted but
/// unused — it exists only to keep `serve()`'s signature uniform across
/// every feature variant of this package.
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  Dispatch.runAwsCustomRuntimeLoop(app)
}
