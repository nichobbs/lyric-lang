//! AwsXRay — AWS X-Ray active tracing for Lyric Lambda handlers.
//! Stability: @experimental — the active-tracing aspect compiles and unit
//! tests cover the AWS X-Ray header shape, but the end-to-end pipeline has not
//! been exercised against a live X-Ray segment service in CI.
//!
//! The Lambda runtime opens a top-level X-Ray segment for every invocation
//! when active tracing is enabled on the Lambda function.  This library
//! wraps individual Lyric function calls as subsegments of that top-level
//! segment via the Tracing pub aspect template.
//!
//! Primary usage: instantiate the Tracing aspect template with a matches
//! selector.  The aspect wraps each matched call in an X-Ray subsegment.
//!
//!   import AwsXRay
//!
//!   aspect TraceHandlers from AwsXRay.Tracing {
//!     matches: name like "handle*"
//!   }
//!
//! The subsegment name is the function's qualified name (e.g.
//! "MyApp.Orders.handleCreate").  On error the subsegment is closed with
//! the error message recorded under the "error" annotation.
//!
//! Secondary usage: attach annotations and metadata to the current subsegment
//! from within a handler body.
//!
//!   func handleCreate(event: ApiGwV2Event, ctx: LambdaContext): Result[ApiGwResponse, LambdaError] {
//!     val seg = AwsXRay.currentSubsegment()
//!     AwsXRay.annotate(seg, "orderId", event.pathParameters.get("id"))
//!     ...
//!   }
//!
//! Annotations are indexed by X-Ray and appear in filter expressions.
//! Metadata is not indexed and can hold arbitrary string values.
//!
//! IAM requirements:
//!   The Lambda execution role must have xray:PutTraceSegments and
//!   xray:PutTelemetryRecords on * (standard X-Ray active tracing policy).
//!
//! See docs/35-lambda-library.md §13, decision log D064.
@runtime_checked
package AwsXRay

import Std.Core
import Std.Char as Ch

// ─── SubsegmentHandle ─────────────────────────────────────────────────────────
/// An active X-Ray subsegment.
/// Valid for the lifetime of the function call wrapped by the Tracing aspect.
/// Do not store beyond the handler's return.
///
/// Exactly one declaration of `SubsegmentHandle` survives `@cfg` erasure per
/// build.  The `local` feature keeps the original zero-field opaque record
/// (no real SDK object exists to hold).  `aws` and `jvm` alias the type
/// directly to the SDK's own entity type — the same "no wrapper record"
/// pattern as `Std.ProcessHost.ProcessHandle = "java.lang.Process"` — so
/// annotate()/metadata() operate on the real, live X-Ray object.
@stable(since = "0.1")
@cfg(feature = "local")
pub opaque type SubsegmentHandle {
  // no-op placeholder: the local feature never talks to the X-Ray SDK
}

/// `Amazon.XRay.Recorder.Core.Internal.Entities.Entity` — the common base of
/// the .NET SDK's `Segment`/`Subsegment` (the `.Internal` namespace segment
/// is real, despite the name — confirmed via `System.Reflection` against the
/// actual `AWSXRayRecorder.Core` package; the type itself is public).
/// `AWSXRayRecorder.GetEntity()` and `BeginSubsegment()`'s produced entity
/// are both assignable to it.
@stable(since = "0.1")
@cfg(feature = "aws")
pub extern type SubsegmentHandle = "Amazon.XRay.Recorder.Core.Internal.Entities.Entity"

/// `com.amazonaws.xray.entities.Entity` — the common interface of the Java
/// SDK's `Segment`/`Subsegment`.  Bound directly (rather than the narrower
/// `Subsegment` interface) because `putAnnotation`/`putMetadata` are
/// declared on `Entity` itself, and every producer here (`beginSubsegment`,
/// `getCurrentSubsegment`, `DummySubsegment`) is a `Subsegment`, which
/// extends `Entity` — a safe, always-legal upcast.
@stable(since = "0.1")
@cfg(feature = "jvm")
pub extern type SubsegmentHandle = "com.amazonaws.xray.entities.Entity"

// ─── Internal platform-dispatch extern boundaries ─────────────────────────────
//
// Exactly one block below survives `@cfg` erasure per build.  Functions are
// named with a kernel_ prefix to avoid conflicts between blocks.  These are
// package-internal; the public API is the pub functions further down.
@cfg(feature = "local")
func kernel_beginSubsegment(name: String): SubsegmentHandle {
  return SubsegmentHandle()
}

@cfg(feature = "local")
func kernel_endSubsegment(handle: SubsegmentHandle): Unit {
}

@cfg(feature = "local")
func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit {
}

@cfg(feature = "local")
func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit {
}

@cfg(feature = "local")
func kernel_currentSubsegment(): SubsegmentHandle {
  return SubsegmentHandle()
}

// ── aws (.NET): Amazon.XRay.Recorder.Core.AWSXRayRecorder ────────────────────
//
// The .NET SDK is ambient/thread-local: `BeginSubsegment`/`EndSubsegment`/
// `AddAnnotation`/`AddMetadata` all act on the recorder's *current* entity
// rather than an explicit handle argument (there is no .NET analogue of the
// Java SDK's instance-returning `beginSubsegment(name): Subsegment`).  The
// `handle` parameters on the public `annotate`/`metadata`/`kernel_endSubsegment`
// functions are accepted for API symmetry with `jvm` but unused on this
// backend — correct because the `Tracing` aspect and `currentSubsegment()`
// always pair a `kernel_beginSubsegment` with the very next
// `kernel_endSubsegment`/annotation on the same call stack, so "current" and
// "the handle we were given" are always the same entity.
//
// `BeginSubsegment`/`EndSubsegment` declare a single trailing optional
// `DateTime? timestamp = null` BCL parameter; the wrappers below omit it and
// rely on `Msil.Codegen`'s trailing-optional-parameter auto-fill, which
// builds the correct `Nullable<DateTime>` default straight from the real
// resolved BCL signature (a Lyric-declared closed-generic `Nullable<T>`
// extern type has no flat TypeRef identity and erases to `object`, which
// does not bind — this auto-fill path is the only one that encodes it
// correctly).
@cfg(feature = "aws")
@axiom("Amazon.XRay.Recorder.Core 2.14.0 — AWSXRayRecorder.Instance is the process-wide ambient recorder")
extern type AwsRecorder = "Amazon.XRay.Recorder.Core.AWSXRayRecorder"

@cfg(feature = "aws")
@externStatic
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorder.get_Instance")
func awsRecorderInstance(): AwsRecorder = ()

// `@externInstance` is required on every wrapper below (#5452): `Msil.Ffi
// .resolveExternTarget`'s `RHEither` branch (no explicit hint) defaults
// `isStatic = true` — silently mis-emitting an instance BCL method as a
// static call with the receiver as an extra parameter, which fails at
// runtime with `MissingMethodException: Method not found` rather than at
// compile time (the F0015 signature-verification pass is itself skipped
// without an explicit hint, so this mis-emission compiles clean).
@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorder.BeginSubsegment")
func awsBeginSubsegment(recorder: in AwsRecorder, name: in String): Unit
  requires: name.length > 0
  = ()

@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorder.EndSubsegment")
func awsEndSubsegment(recorder: in AwsRecorder): Unit = ()

// `AddAnnotation`/`AddMetadata` are declared on `AWSXRayRecorderImpl` (the
// base class `AWSXRayRecorder` inherits from — confirmed via
// `System.Reflection`, same as `GetEntity`/`IsEntityPresent` below), and
// their real BCL signature takes `object value`, not `string value`.
// Targeting the base class directly matters here specifically because
// these two calls carry a non-trivial (non-empty) parameter list: the
// metadata-resolved auto-FFI signature correction in
// `Msil.Codegen.emitExternTargetBody` (which would otherwise fix up the
// `String` → `object` mismatch automatically) only fires when
// `findTypeDefByFqn` can locate the member on the exact TypeDef the
// `@externTarget` names — it does not walk the superclass chain, so naming
// `AWSXRayRecorder` here would silently fall back to the Lyric-declared
// (wrong: `string`) parameter encoding and fail at runtime with
// `MissingMethodException`.  `GetEntity`/`IsEntityPresent` are unaffected
// by the same gap only because they take zero parameters — nothing in
// their signature can be wrong regardless of which lookup path is taken.
@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorderImpl.AddAnnotation")
func awsAddAnnotation(recorder: in AwsRecorder, key: in String, value: in String): Unit
  requires: key.length > 0
  = ()

@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorderImpl.AddMetadata")
func awsAddMetadata(recorder: in AwsRecorder, key: in String, value: in String): Unit
  requires: key.length > 0
  = ()

@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorder.GetEntity")
func awsGetEntity(recorder: in AwsRecorder): SubsegmentHandle = ()

@cfg(feature = "aws")
@externInstance
@externTarget("Amazon.XRay.Recorder.Core.AWSXRayRecorder.IsEntityPresent")
func awsIsEntityPresent(recorder: in AwsRecorder): Bool = ()

// `awsGetEntity` (`AWSXRayRecorder.GetEntity()`) throws when no
// segment/subsegment is active — unlike every other recorder call used in
// this kernel, which the SDK's default `LogErrorContextMissingStrategy`
// makes a silent no-op instead (verified directly against the real SDK:
// `BeginSubsegment`/`EndSubsegment`/`AddAnnotation`/`AddMetadata` all
// tolerate a missing context; only `GetEntity` raises).  `awsSafeEntity`
// centralises the guard: `IsEntityPresent()` first, `GetEntity()` only when
// it will succeed, `default()` (a null `Entity` reference) otherwise.  A
// null handle is safe here specifically because every consumer on this
// backend (`kernel_endSubsegment`/`kernel_addAnnotation`/
// `kernel_addMetadata`) ignores its `handle` parameter entirely — the .NET
// SDK is ambient (see the file-header note above) — so nothing ever
// dereferences the value.
@cfg(feature = "aws")
func awsSafeEntity(recorder: in AwsRecorder): SubsegmentHandle {
  if awsIsEntityPresent(recorder) {
    awsGetEntity(recorder)
  } else {
    val noHandle: SubsegmentHandle = default()
    noHandle
  }
}

@cfg(feature = "aws")
func kernel_beginSubsegment(name: String): SubsegmentHandle {
  val recorder = awsRecorderInstance()
  awsBeginSubsegment(recorder, name)
  awsSafeEntity(recorder)
}

@cfg(feature = "aws")
func kernel_endSubsegment(handle: SubsegmentHandle): Unit {
  awsEndSubsegment(awsRecorderInstance())
}

@cfg(feature = "aws")
func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit {
  awsAddAnnotation(awsRecorderInstance(), key, value)
}

@cfg(feature = "aws")
func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit {
  awsAddMetadata(awsRecorderInstance(), key, value)
}

@cfg(feature = "aws")
func kernel_currentSubsegment(): SubsegmentHandle {
  awsSafeEntity(awsRecorderInstance())
}

// ── jvm: com.amazonaws.xray.AWSXRay / AWSXRayRecorder ─────────────────────────
//
// `AWSXRayRecorder.beginSubsegment(name): Subsegment` returns the real
// subsegment object (unlike .NET, which is purely ambient) — the JVM
// `handle` is a genuine live reference, so `annotate`/`metadata` call
// `putAnnotation`/`putMetadata` directly on it rather than going through the
// recorder.  `Entity`/`Subsegment` are ordinary Java interfaces; dispatching
// an instance method against them requires the self-hosted JVM auto-FFI
// backend to resolve interfaces at all and emit `invokeinterface` instead of
// the class-only `invokevirtual` — landed in `lyric-compiler/jvm/
// class_reader.l` / `lyric-compiler/jvm/codegen/04_calls.l` /
// `lyric-compiler/jvm/auto_ffi.l` as part of `lyric-session`'s Lettuce
// Redis kernel work (D-progress-631), which needed the same fix plus a
// recursive superinterface walk.
@cfg(feature = "jvm")
@axiom("com.amazonaws:aws-xray-recorder-sdk-core 2.15.3 — AWSXRay.getGlobalRecorder / AWSXRayRecorder")
extern type XAWSXRay = "com.amazonaws.xray.AWSXRay"

@cfg(feature = "jvm")
extern type XRecorder = "com.amazonaws.xray.AWSXRayRecorder"

@cfg(feature = "jvm")
extern type XDummySubsegment = "com.amazonaws.xray.entities.DummySubsegment"

@cfg(feature = "jvm")
func jvmRecorder(): XRecorder {
  XAWSXRay.getGlobalRecorder()
}

@cfg(feature = "jvm")
func kernel_beginSubsegment(name: String): SubsegmentHandle {
  jvmRecorder().beginSubsegment(name)
}

@cfg(feature = "jvm")
func kernel_endSubsegment(handle: SubsegmentHandle): Unit {
  jvmRecorder().endSubsegment()
}

@cfg(feature = "jvm")
func kernel_addAnnotation(handle: SubsegmentHandle, key: String, value: String): Unit {
  handle.putAnnotation(key, value)
}

@cfg(feature = "jvm")
func kernel_addMetadata(handle: SubsegmentHandle, key: String, value: String): Unit {
  handle.putMetadata(key, value)
}

@cfg(feature = "jvm")
func kernel_currentSubsegment(): SubsegmentHandle {
  val recorder = jvmRecorder()
  val current = recorder.getCurrentSubsegment()
  match current {
    case null -> XDummySubsegment.new(recorder)
    case _ -> current
  }
}

// ─── Manual subsegment lifecycle ──────────────────────────────────────────────
/// Open a new subsegment named `name` and make it the active subsegment.
/// The `Tracing` aspect template is the usual way to create subsegments
/// (one per matched function call); call this directly for programmatic
/// control over subsegment boundaries instead of (or nested inside) an
/// aspect-wrapped call.  Pair every `beginSubsegment` with an `endSubsegment`
/// on the same handle.
@stable(since = "0.1")
pub func beginSubsegment(name: in String): SubsegmentHandle
  requires: name.length > 0
{
  return kernel_beginSubsegment(name)
}

/// Close a subsegment opened by `beginSubsegment` (or by the `Tracing`
/// aspect).  No-op when built with the local feature.
@stable(since = "0.1")
pub func endSubsegment(handle: in SubsegmentHandle): Unit {
  kernel_endSubsegment(handle)
}

// ─── Helpers available inside wrapped handlers ────────────────────────────────
/// Return the active subsegment opened by the enclosing Tracing aspect call
/// (or by `beginSubsegment`).  Returns a no-op handle when called outside an
/// active subsegment or when the local feature is active.
@stable(since = "0.1")
pub func currentSubsegment(): SubsegmentHandle {
  return kernel_currentSubsegment()
}

/// Add an indexed X-Ray annotation to the subsegment.
/// Annotations appear in X-Ray filter expressions (e.g. annotation.orderId = "123").
/// Both key and value must be non-empty strings.
/// No-op when built with the local feature.
@cfg(feature = "local")
@stable(since = "0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
}

@cfg(feature = "aws")
@stable(since = "0.1")
pub func annotate(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addAnnotation(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
}

@cfg(feature = "jvm")
@stable(since = "0.1")
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
@stable(since = "0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
}

@cfg(feature = "aws")
@stable(since = "0.1")
pub func metadata(handle: in SubsegmentHandle, key: in String, value: in String): Unit
  requires: key.length > 0
  requires: value.length > 0
{
  kernel_addMetadata(handle, sanitizeAnnotation(key), sanitizeAnnotation(value))
}

@cfg(feature = "jvm")
@stable(since = "0.1")
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
@stable(since = "0.1")
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
        case Err(e) -> {
          kernel_addAnnotation(seg, "error", sanitizeAnnotation(e.toString()))
        }
        case _ -> ()
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
  if code < 0x80 {
    1
  } else if code < 0x800 {
    2
  } else {
    3
  }
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
