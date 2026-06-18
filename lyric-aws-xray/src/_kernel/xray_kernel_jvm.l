//! AwsXRay.Kernel.Net (jvm) — AWS X-Ray SDK for Java extern boundary.
//!
//! Bridges AwsXRay to the AWS X-Ray Recorder SDK for Java:
//!   com.amazonaws:aws-xray-recorder-sdk-core — AWSXRay singleton
//!
//! beginSubsegment(name):
//!   Calls AWSXRay.beginSubsegment(name) on the global recorder.  The SDK
//!   attaches the subsegment to the current segment on the thread-local
//!   context.  Returns an opaque SubsegmentHandle wrapping the Subsegment
//!   reference.
//!
//! endSubsegment(handle):
//!   Calls AWSXRay.endSubsegment().  Marks the subsegment complete and
//!   queues it for emission to the X-Ray daemon.
//!
//! addAnnotation(handle, key, value):
//!   Calls handle.putAnnotation(key, value).  Annotations are indexed by
//!   X-Ray and searchable via filter expressions.
//!
//! addMetadata(handle, key, value):
//!   Calls handle.putMetadata(key, value).  Metadata is visible in the trace
//!   view but not searchable.
//!
//! currentSubsegment():
//!   Returns an opaque handle wrapping AWSXRay.getCurrentSubsegmentOptional().
//!   Returns a sentinel no-op handle if no subsegment is active.
//!
//! Thread safety:
//!   The Java X-Ray SDK uses a thread-local TraceContext; each thread/virtual
//!   thread has an isolated segment stack.
//!
//! Maven dependency (resolved when feature = "jvm"):
//!   com.amazonaws:aws-xray-recorder-sdk-core:2.15.3
//!
//! Enabled only when the "jvm" feature flag is active.
//! See docs/35-lambda-library.md §13.4.
@cfg(feature = "jvm")
package AwsXRay.Kernel.Net

import AwsXRay

@axiom("com.amazonaws:aws-xray-recorder-sdk-core 2.15.3 — AWSXRay.beginSubsegment / endSubsegment")
extern package com.amazonaws.xray {
  pub func beginSubsegment(name: String): AwsXRay.SubsegmentHandle
    requires: name.length > 0

  pub func endSubsegment(handle: AwsXRay.SubsegmentHandle): Unit

  pub func addAnnotation(handle: AwsXRay.SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0

  pub func addMetadata(handle: AwsXRay.SubsegmentHandle, key: String, value: String): Unit
    requires: key.length > 0

  pub func currentSubsegment(): AwsXRay.SubsegmentHandle
}
