// Lambda.Kernel.Runtime (jvm) — AWS Java managed runtime extern boundary.
//
// On the JVM target, Lambda functions run under the managed Java runtime
// (amazon.corretto / java21).  The Lambda service invokes the handler class
// directly via the `RequestStreamHandler` interface; no custom runtime polling
// loop is needed.
//
// Dispatch protocol:
//   1. At startup the kernel registers each route / handler / authorizer
//      from the LambdaApp with the Java Lambda runtime.
//   2. For each invocation the runtime calls `handleRequest(InputStream, OutputStream, Context)`.
//   3. The kernel reads the raw JSON from InputStream, detects the event source
//      (same rules as the .NET kernel), and dispatches:
//        HTTP + httpRouter     → router dispatch, serialise to API GW response JSON
//        HTTP + streamingHandler → StreamWriter wrapping the OutputStream
//        Authorizer invocation → authorizer handler, serialise IAM / HttpAuthorizer response
//        Event source          → deserialise to typed record, invoke handler
//        DirectHandler entries → resolve delegate directly (no reflection)
//   4. Write the response JSON to OutputStream and close.
//
// JVM handler class:
//   The Lyric JVM emitter generates a class `<RootPackage>$LambdaHandler`
//   implementing `com.amazonaws.services.lambda.runtime.RequestStreamHandler`.
//   Set the handler in the Lambda function config to:
//     `<assembly-name>.<RootPackage>$LambdaHandler::handleRequest`
//
// Streaming:
//   When a streaming handler is registered, the kernel writes output directly
//   to the OutputStream without buffering.  Function URL InvokeMode must be
//   set to RESPONSE_STREAM.  Chunked transfer is managed by the Lambda runtime.
//
// Maven dependencies (resolved when target = "jvm"):
//   com.amazonaws:aws-lambda-java-core:1.2.3
//   com.amazonaws:aws-lambda-java-events:3.11.4
//
// See docs/35-lambda-library.md §12.2, docs/18-jvm-emission.md, D064.

@cfg(feature = "jvm")
package Lambda.Kernel.Runtime

import Lambda
import Web

@axiom("AWS Java managed runtime — com.amazonaws:aws-lambda-java-core 1.2.3 + aws-lambda-java-events 3.11.4")
extern package com.amazonaws.lambda {
  /// Register the LambdaApp with the Java Lambda managed runtime.
  /// Blocks until the Lambda execution environment exits the JVM process.
  pub func serve(
    app:       LambdaApp,
    localPort: Int
  ): Unit
}

/// Start the JVM Lambda managed runtime (delegates to com.amazonaws.lambda).
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  com.amazonaws.lambda.serve(app, localPort)
}
