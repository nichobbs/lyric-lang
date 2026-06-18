// AwsXRay.Kernel.Net (local) — no-op extern boundary for local development.
//
// All X-Ray calls are silently dropped; no X-Ray daemon or AWS credentials
// are required.  Subsegment handles are replaced by a zero-overhead sentinel.
//
// This allows Lambda handlers instrumented with AwsXRay.Tracing to run under
// the `local` feature (e.g. `lyric build --features local`) without any AWS
// infrastructure.  Active tracing is simply absent from the local run; the
// handles returned are safe to pass to annotate() / metadata() which also
// become no-ops.
//
// Enabled only when the "local" feature flag is active.
// See docs/35-lambda-library.md §13.2.

@cfg(feature = "local")
package AwsXRay.Kernel.Net

import AwsXRay

@axiom("no-op local implementation — no AWS X-Ray daemon required")
extern package lyric.xray.local {
  pub func beginSubsegment(name: String): AwsXRay.SubsegmentHandle

  pub func endSubsegment(handle: AwsXRay.SubsegmentHandle): Unit

  pub func addAnnotation(
    handle: AwsXRay.SubsegmentHandle,
    key:    String,
    value:  String
  ): Unit

  pub func addMetadata(
    handle: AwsXRay.SubsegmentHandle,
    key:    String,
    value:  String
  ): Unit

  pub func currentSubsegment(): AwsXRay.SubsegmentHandle
}
