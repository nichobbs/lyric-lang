/// AwsXRay — AWS X-Ray active tracing for Lyric Lambda handlers.
///
/// The Lambda runtime opens a top-level X-Ray segment for every invocation
/// when active tracing is enabled on the Lambda function.  This library
/// wraps individual Lyric function calls as subsegments of that top-level
/// segment via the Tracing pub aspect template.
///
/// Primary usage: instantiate the Tracing aspect template with a matches
/// selector.  The aspect wraps each matched call in an X-Ray subsegment.
///
///   import AwsXRay
///
///   aspect TraceHandlers from AwsXRay.Tracing {
///     matches: name like "handle*"
///   }
///
/// The subsegment name is the function's qualified name (e.g.
/// "MyApp.Orders.handleCreate").  On error the subsegment is closed with
/// the error message recorded under the "error" annotation.
///
/// Secondary usage: attach annotations and metadata to the current subsegment
/// from within a handler body.
///
///   func handleCreate(event: ApiGwV2Event, ctx: LambdaContext): Result[ApiGwResponse, LambdaError] {
///     val seg = AwsXRay.currentSubsegment()
///     AwsXRay.annotate(seg, "orderId", event.pathParameters.get("id"))
///     ...
///   }
///
/// Annotations are indexed by X-Ray and appear in filter expressions.
/// Metadata is not indexed and can hold arbitrary string values.
///
/// IAM requirements:
///   The Lambda execution role must have xray:PutTraceSegments and
///   xray:PutTelemetryRecords on * (standard X-Ray active tracing policy).
///
/// See docs/35-lambda-library.md §13, decision log D064.

@runtime_checked
package AwsXRay

import Std.Core
import AwsXRay.Kernel.Net as XRayKernel

// ─── SubsegmentHandle ─────────────────────────────────────────────────────────

/// An active X-Ray subsegment.
/// Valid for the lifetime of the function call wrapped by the Tracing aspect.
/// Do not store beyond the handler's return.
@stable(since="0.1")
pub opaque type SubsegmentHandle {
  // kernel-managed subsegment reference
}

// ─── Helpers available inside wrapped handlers ────────────────────────────────

/// Return the active subsegment opened by the enclosing Tracing aspect call.
/// Returns a no-op handle when called outside an aspect-wrapped function or
/// when the local feature is active.
@stable(since="0.1")
pub func currentSubsegment(): SubsegmentHandle {
  return XRayKernel.currentSubsegment()
}

/// Add an indexed X-Ray annotation to the subsegment.
/// Annotations appear in X-Ray filter expressions (e.g. annotation.orderId = "123").
/// Both key and value must be non-empty strings.
@stable(since="0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  XRayKernel.addAnnotation(handle, key, value)
}

/// Add unindexed metadata to the subsegment.
/// Metadata is visible in the X-Ray console but not searchable via filter expressions.
/// Both key and value must be non-empty strings.
@stable(since="0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  XRayKernel.addMetadata(handle, key, value)
}

// ─── Tracing aspect template ──────────────────────────────────────────────────

/// Wrap each matched function call in an X-Ray subsegment.
///
/// B-mode: uses only call.qualifiedName so it composes generically across
/// all matched handlers regardless of their parameter shapes.
///
/// Subsegment lifecycle:
///   1. Before the call: beginSubsegment(call.qualifiedName).
///   2. The call proceeds.
///   3. On Err(_): record the error message as an annotation; end the subsegment.
///   4. On Ok(_) or non-Result return: end the subsegment cleanly.
///
/// Compose this inside Lambda.Aspects.EventLogging (outside = TraceHandlers)
/// so timing is measured around the full subsegment including X-Ray overhead.
///
/// Config fields (env: LYRIC_ASPECT_<INSTANTIATION>_<FIELD>):
///   enabled Bool — master switch; when false the aspect is a transparent pass-through
///                  (default: true)
@stable(since="0.1")
pub aspect Tracing {
  config {
    enabled: Bool = true
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val seg = XRayKernel.beginSubsegment(call.qualifiedName)
      ret = call.proceed()
      match ret {
        Err(e) => XRayKernel.addAnnotation(seg, "error", sanitizeAnnotation(e.toString()))
        _      => ()
      }
      XRayKernel.endSubsegment(seg)
    }
  }
}

// ─── Internal helpers ────────────────────────────────────────────────────────

// Sanitise an X-Ray annotation value to defend against log-injection /
// stored-XSS in trace viewers (CWE-117).  X-Ray annotation values appear
// in the AWS console (often searchable, sometimes rendered as HTML by
// downstream dashboards) and may contain user-controlled content via
// validation errors that echo submitted values.  This function:
//
//   1. Replaces CR / LF / NUL / TAB with single spaces so the value
//      stays on one line and cannot smuggle structured log fields.
//   2. Replaces `<` / `>` so a naive HTML-rendering viewer cannot
//      interpret embedded tags.
//   3. Caps the length at 1000 characters; X-Ray's own limit is 1024
//      bytes per annotation value, and overlong values are usually
//      bug-spam rather than useful trace data.
//
// Kept private — `lyric-aws-xray` is the only library producing X-Ray
// annotations.  A generic `Std.Log.sanitize` lives in the stdlib log
// module (see lyric-lang #394).
func sanitizeAnnotation(s: in String): String {
  val a = s.replace("\r", " ").replace("\n", " ").replace("\u{0000}", " ").replace("\t", " ")
  val b = a.replace("<", "_").replace(">", "_")
  if b.length > 1000 { b.substring(0, 1000) } else { b }
}
