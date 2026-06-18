// Lambda.Stream — response streaming for Lambda Function URLs and HTTP API streaming.
//
// Lambda response streaming reduces time-to-first-byte for large or progressive
// HTTP responses by letting the handler write output chunks before the handler
// returns.  AWS delivers each chunk to the caller as it is written; the caller
// does not wait for the full response.
//
// Supported frontends:
//   Lambda Function URL — set InvokeMode: RESPONSE_STREAM on the URL config.
//   API Gateway HTTP API — supported via streaming integration (limited availability;
//                          check current AWS documentation for region support).
//
// Handler signature (string-based registration via Lambda.withStreamingHandler):
//   func h(rawEvent: String, ctx: Lambda.LambdaContext, writer: Lambda.Stream.StreamWriter): Result[Unit, LambdaError]
//
//   rawEvent is the full API Gateway / Function URL event JSON.  Parse it
//   with Lambda.ApiGw types if structured access is needed.
//   writer is valid only for the lifetime of the handler call.
//
// Handler signature (AOT-safe registration via Lambda.Direct.streamingHandler):
//   Same — accepts rawEvent as String.
//
// Example:
//
//   func streamTokens(rawEvent: String, ctx: Lambda.LambdaContext, writer: Lambda.Stream.StreamWriter)
//       : Result[Unit, LambdaError] {
//     Lambda.Stream.setContentType(writer, "text/event-stream")
//     val tokens = MyApp.Llm.generate(rawEvent)
//     for token in tokens {
//       match Lambda.Stream.write(writer, "data: " + token + "\n\n") {
//         Ok(_)    => ()
//         Err(err) => return Err(err)
//       }
//     }
//     Lambda.Stream.close(writer)
//     return Ok(())
//   }
//
//   Lambda.serve(
//     Lambda.newApp()
//       |> Lambda.withStreamingHandler("MyApp.Llm.streamTokens"))
//
// Notes:
//   - Do not mix streaming handlers with a Web.Router in the same LambdaApp.
//     withStreamingHandler routes all HTTP traffic to the single streaming
//     handler; the router is not consulted.
//   - close() is called automatically if the handler returns before calling it.
//   - After close() returns, further write() calls return LambdaError.InternalError.
//   - The Content-Type header must be set before the first write() call.
//     If not set, the kernel uses "application/octet-stream".
//
// See docs/35-lambda-library.md §11, decision log D064.

@runtime_checked
package Lambda.Stream

import Std.Core
import Web
import Lambda

// ─── StreamWriter ─────────────────────────────────────────────────────────────

/// An active response stream for a Lambda streaming invocation.
/// Valid only within the handler call that received it; do not store beyond
/// the handler's return.
@stable(since="0.1")
pub opaque type StreamWriter {
  // kernel-managed write channel
}

/// Set the Content-Type header of the streaming response.
/// Must be called before the first write() or writeBytes() call.
/// Calling after the first chunk is written has no effect.
@stable(since="0.1")
pub func setContentType(writer: in StreamWriter, contentType: in String): Unit
  requires: contentType.length > 0

/// Write a UTF-8 string chunk to the response stream.
/// Each call delivers the chunk to the caller immediately.
/// Returns LambdaError.InternalError if the stream is already closed or
/// the connection was dropped by the caller.
@stable(since="0.1")
pub func write(writer: in StreamWriter, chunk: in String): Result[Unit, LambdaError]
  requires: chunk.length > 0

/// Write a base64-encoded binary chunk to the response stream.
/// The kernel decodes the base64 and delivers raw bytes to the caller.
@stable(since="0.1")
pub func writeBytes(writer: in StreamWriter, base64Chunk: in String): Result[Unit, LambdaError]
  requires: base64Chunk.length > 0

/// Close the response stream.
/// Signals to the caller that the response is complete.
/// Called automatically if the handler returns without closing.
@stable(since="0.1")
pub func close(writer: in StreamWriter): Unit
