// AwsXRay.Kernel.Net (aws) — Amazon.XRay.Recorder.Core extern boundary (.NET).
//
// Bridges AwsXRay to the AWS X-Ray Recorder SDK for .NET:
//   Amazon.XRay.Recorder.Core — AWSXRayRecorder singleton
//
// beginSubsegment(name):
//   Calls AWSXRayRecorder.Instance.BeginSubsegment(name).  The SDK adds the
//   subsegment to the active entity (segment or parent subsegment) on the
//   current async context.  Returns an opaque SubsegmentHandle wrapping the
//   created entity reference.
//
// endSubsegment(handle):
//   Calls AWSXRayRecorder.Instance.EndSubsegment().  Marks the subsegment
//   complete and queues it for emission to the X-Ray daemon.
//
// addAnnotation(handle, key, value):
//   Calls AWSXRayRecorder.Instance.AddAnnotation(key, value).  Annotations
//   are indexed by X-Ray and searchable via filter expressions.
//
// addMetadata(handle, key, value):
//   Calls AWSXRayRecorder.Instance.AddMetadata(key, value).  Metadata is
//   visible in the trace view but not searchable.
//
// currentSubsegment():
//   Returns an opaque handle wrapping the current entity on the async context.
//   Returns a sentinel no-op handle if no segment is active.
//
// Thread safety:
//   The .NET X-Ray SDK uses AsyncLocalSegmentContext to track the active
//   entity per async execution flow; concurrent handlers are isolated.
//
// NuGet dependency (resolved when feature = "aws"):
//   Amazon.XRay.Recorder.Core 2.14.0
//
// Enabled only when the "aws" feature flag is active.
// See docs/35-lambda-library.md §13.3.

@cfg(feature = "aws")
package AwsXRay.Kernel.Net

import AwsXRay

@axiom("Amazon.XRay.Recorder.Core 2.14.0 — AWSXRayRecorder.Instance")
extern package Amazon.XRay.Recorder {
  pub func beginSubsegment(name: String): AwsXRay.SubsegmentHandle
    requires: name.length > 0

  pub func endSubsegment(handle: AwsXRay.SubsegmentHandle): Unit

  pub func addAnnotation(
    handle: AwsXRay.SubsegmentHandle,
    key:    String,
    value:  String
  ): Unit
    requires: key.length > 0

  pub func addMetadata(
    handle: AwsXRay.SubsegmentHandle,
    key:    String,
    value:  String
  ): Unit
    requires: key.length > 0

  pub func currentSubsegment(): AwsXRay.SubsegmentHandle
}
