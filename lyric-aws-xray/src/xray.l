// AwsXRay — AWS X-Ray active tracing for Lyric Lambda handlers.
// Stability: @experimental — the active-tracing aspect compiles and unit
// tests cover the AWS X-Ray header shape, but the end-to-end pipeline has not
// been exercised against a live X-Ray segment service in CI.
//
// The Lambda runtime opens a top-level X-Ray segment for every invocation
// when active tracing is enabled on the Lambda function.  This library
// wraps individual Lyric function calls as subsegments of that top-level
// segment via the Tracing pub aspect template.
//
// Primary usage: instantiate the Tracing aspect template with a matches
// selector.  The aspect wraps each matched call in an X-Ray subsegment.
//
//   import AwsXRay
//
//   aspect TraceHandlers from AwsXRay.Tracing {
//     matches: name like "handle*"
//   }
//
// The subsegment name is the function's qualified name (e.g.
// "MyApp.Orders.handleCreate").  On error the subsegment is closed with
// the error message recorded under the "error" annotation.
//
// Secondary usage: attach annotations and metadata to the current subsegment
// from within a handler body.
//
//   func handleCreate(event: ApiGwV2Event, ctx: LambdaContext): Result[ApiGwResponse, LambdaError] {
//     val seg = AwsXRay.currentSubsegment()
//     AwsXRay.annotate(seg, "orderId", event.pathParameters.get("id"))
//     ...
//   }
//
// Annotations are indexed by X-Ray and appear in filter expressions.
// Metadata is not indexed and can hold arbitrary string values.
//
// IAM requirements:
//   The Lambda execution role must have xray:PutTraceSegments and
//   xray:PutTelemetryRecords on * (standard X-Ray active tracing policy).
//
// See docs/35-lambda-library.md §13, decision log D064.

@runtime_checked
package AwsXRay

import Std.Core
import Std.Char as Ch

// ─── SubsegmentHandle ─────────────────────────────────────────────────────────

/// An active X-Ray subsegment.
/// Valid for the lifetime of the function call wrapped by the Tracing aspect.
/// Do not store beyond the handler's return.
@stable(since="0.1")
pub opaque type SubsegmentHandle {
  // kernel-managed subsegment reference
}

// ─── Internal platform-dispatch extern boundaries ─────────────────────────────
//
// Exactly one extern package block is active per build (selected by @cfg).
// Functions are named with a kernel_ prefix to avoid conflicts between blocks.
// These are package-internal; the public API is the pub functions below.

@cfg(feature = "local")
func kernel_beginSubsegment(name: String): SubsegmentHandle {
  return SubsegmentHandle()
}

@cfg(feature = "local")
func kernel_endSubsegment(handle: SubsegmentHandle): Unit { }

@cfg(feature = "local")
func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit { }

@cfg(feature = "local")
func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit { }

@cfg(feature = "local")
func kernel_currentSubsegment(): SubsegmentHandle {
  return SubsegmentHandle()
}

@cfg(feature = "aws")
@axiom("Amazon.XRay.Recorder.Core 2.14.0 — AWSXRayRecorder.Instance")
extern package Amazon.XRay.Recorder {
  func kernel_beginSubsegment(name: String): SubsegmentHandle
    requires: name.length > 0
  func kernel_endSubsegment(handle: SubsegmentHandle): Unit
  func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0
  func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0
  func kernel_currentSubsegment(): SubsegmentHandle
}

@cfg(feature = "jvm")
@axiom("com.amazonaws:aws-xray-recorder-sdk-core 2.15.3 — AWSXRay.beginSubsegment / endSubsegment")
extern package com.amazonaws.xray {
  func kernel_beginSubsegment(name: String): SubsegmentHandle
    requires: name.length > 0
  func kernel_endSubsegment(handle: SubsegmentHandle): Unit
  func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0
  func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0
  func kernel_currentSubsegment(): SubsegmentHandle
}

// ─── Helpers available inside wrapped handlers ────────────────────────────────

/// Return the active subsegment opened by the enclosing Tracing aspect call.
/// Returns a no-op handle when called outside an aspect-wrapped function or
/// when the local feature is active.
@stable(since="0.1")
pub func currentSubsegment(): SubsegmentHandle {
  return kernel_currentSubsegment()
}

/// Add an indexed X-Ray annotation to the subsegment.
/// Annotations appear in X-Ray filter expressions (e.g. annotation.orderId = "123").
/// Both key and value must be non-empty strings.
/// No-op when built with the local feature.
@cfg(feature = "local")
@stable(since="0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{ }

@cfg(feature = "aws")
@stable(since="0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addAnnotation(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
}

@cfg(feature = "jvm")
@stable(since="0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addAnnotation(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
}

/// Add unindexed metadata to the subsegment.
/// Metadata is visible in the X-Ray console but not searchable via filter expressions.
/// Both key and value must be non-empty strings.
/// No-op when built with the local feature.
@cfg(feature = "local")
@stable(since="0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{ }

@cfg(feature = "aws")
@stable(since="0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addMetadata(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
}

@cfg(feature = "jvm")
@stable(since="0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addMetadata(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
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
      val seg = kernel_beginSubsegment(call.qualifiedName)
      ret = call.proceed()
      match ret {
        case Err(e) -> { kernel_addAnnotation(seg, "error", sanitizeAnnotation(e.toString())) }
        case _      -> ()
      }
      kernel_endSubsegment(seg)
    }
  }
}

// Return the number of UTF-8 bytes needed to encode a single BMP Char.
// Surrogate halves (U+D800–U+DFFF) are counted as 3 bytes each — they
// are technically invalid in UTF-8 but this is a conservative safe bound.
func utf8CharBytes(c: in Char): Int {
  val code = Ch.toInt(c)
  if code < 0x80 { 1 } else if code < 0x800 { 2 } else { 3 }
}

// CWE-117 defense: replace structured-log / HTML injection chars and cap below X-Ray's 1024-byte limit.
// Truncation is by UTF-8 byte count (not character count) so multi-byte characters
// cannot push the encoded form over the limit.  Single forward pass: O(n).
func sanitizeAnnotation(s: in String): String {
  val a = s.replace("\r", " ").replace("\n", " ").replace("\u{0000}", " ").replace("\t", " ")
  val b = a.replace("<", "_").replace(">", "_")
  // Single forward pass: accumulate byte count and stop at the 1024-byte limit.
  var byteCount = 0
  var charCount = 0
  var i = 0
  var stop = false
  while i < b.length and not stop {
    val bytes = utf8CharBytes(b[i])
    if byteCount + bytes > 1024 {
      stop = true
    } else {
      byteCount = byteCount + bytes
      charCount = charCount + 1
      i = i + 1
    }
  }
  if charCount == b.length {
    return b
  }
  b.substring(0, charCount)
}
