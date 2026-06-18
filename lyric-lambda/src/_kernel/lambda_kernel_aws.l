// Lambda.Kernel.Runtime (aws) — Amazon.Lambda.RuntimeSupport extern boundary.
//
// Implements the AWS Lambda custom runtime invocation loop:
//   1. GET  $AWS_LAMBDA_RUNTIME_API/2018-06-01/runtime/invocation/next
//        Returns the raw event JSON payload plus three headers:
//          Lambda-Runtime-Aws-Request-Id     → LambdaContext.requestId
//          Lambda-Runtime-Deadline-Ms        → LambdaContext.remainingTimeMs
//          Lambda-Runtime-Invoked-Function-Arn → LambdaContext.invokedFunctionArn
//   2. Detect the event source by inspecting the payload JSON structure:
//        version="2.0" + requestContext.http  → ApiGwV2 (HTTP API)
//        httpMethod + requestContext.resourceId → ApiGwV1 (REST API)
//        requestContext.elb                  → Alb
//        Records[0].eventSource="aws:sqs"    → SQS
//        Records[0].eventSource="aws:sns"    → SNS
//        Records[0].eventSource="aws:s3"     → S3
//        Records[0].eventSource="aws:dynamodb" → DynamoDB
//        source + detail-type                → EventBridge
//        (none of the above)                 → Raw (String)
//   3. Dispatch:
//        HTTP event + LambdaApp.httpRouter present
//          → map method/path/headers/body to Web.Route dispatch
//          → serialise Result[T, Web.ApiError] → ApiGwResponse JSON
//        Non-HTTP event → resolve handlerName from LambdaApp.eventHandlers
//          by eventSource key → deserialise payload to handler's first param
//          → invoke(handler, event, ctx) → serialise result
//        No matching handler → respond with LambdaError.InternalError
//   4. POST $runtimeApi/runtime/invocation/{requestId}/response on Ok
//      POST $runtimeApi/runtime/invocation/{requestId}/error    on Err
//        Error body: { "errorType": "...", "errorMessage": "..." }
//   5. Repeat indefinitely until the execution environment exits the process.
//
// The localPort parameter is accepted but unused in this feature variant;
// it is present to keep the serve() signature uniform across both kernels.
//
// Enabled only when the "aws" feature flag is active.
// See docs/35-lambda-library.md §Kernel, docs/14-native-stdlib-plan.md.

@cfg(feature = "aws")
package Lambda.Kernel.Runtime

import Lambda
import Web

/// Start the custom runtime invocation loop via Amazon.Lambda.RuntimeSupport.
/// Blocks until the Lambda execution environment terminates the process.
@axiom("Amazon.Lambda.RuntimeSupport 1.x custom runtime loop (Bootstrap handler model)")
extern package Amazon.Lambda.RuntimeSupport {
  /// Poll the Lambda Runtime API for events and dispatch each invocation.
  /// Serialises/deserialises event payloads using System.Text.Json.
  /// Resolves handler functions from the compiled DLL via reflection on
  /// the qualified names stored in LambdaApp.eventHandlers[*].handlerName.
  pub func serve(
    app:       Lambda.LambdaApp,
    localPort: Int
  ): Unit
}

/// Start the Lambda invocation loop (delegates to Amazon.Lambda.RuntimeSupport).
pub func serve(app: in LambdaApp, localPort: in Int): Unit {
  Amazon.Lambda.RuntimeSupport.serve(app, localPort)
}
