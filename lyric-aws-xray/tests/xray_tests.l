//! tests/xray_tests.l — tests for lyric-aws-xray, run against all three
//! backends (`local`, `aws`, `jvm`).
//!
//! `currentSubsegment()`/`annotate()`/`metadata()` drive the real AWS X-Ray
//! SDK for `aws`/`jvm` (Amazon.XRay.Recorder.Core / aws-xray-recorder-sdk-core)
//! — no X-Ray daemon or AWS credentials are required for these assertions:
//! both SDKs are designed to run without a live daemon (segment emission is
//! fire-and-forget UDP, silently dropped when nothing is listening) and
//! default to a log-and-continue ContextMissingStrategy for every operation
//! this library calls except `AWSXRayRecorder.GetEntity()` (.NET) — `src/
//! xray.l`'s `awsSafeEntity` guards that one specifically with
//! `IsEntityPresent()` and returns a null (but harmless — `annotate`/
//! `metadata`/`AwsXRay.endSubsegment` never dereference the handle on `aws`;
//! the SDK is ambient) handle instead of letting it throw.  What these tests
//! do NOT verify is that a real X-Ray backend actually *receives* the
//! emitted trace data — that needs a live daemon or the X-Ray console, which
//! is out of scope for an offline test suite (see README "Platform parity").
//!
//! Deliberately does NOT exercise the `Tracing` aspect template here: a
//! cross-package `from AwsXRay.Tracing { ... }` instantiation is B'-mode
//! (the template has no `@inline_template`), and B'-mode's cross-package
//! call-context codegen has a pre-existing JVM-only weaver bug (tracked
//! separately, see `aspect_weave_self_test.l`'s header note on multi-file
//! B'-mode coverage) unrelated to this library's SDK bindings — it throws
//! `NoSuchMethodError` on the synthesised `__LyricBModeCallContext` at
//! runtime on `--target jvm` (`local`/`aws` on `--target dotnet` are
//! unaffected).  The lifecycle test below drives the exact same
//! `AwsXRay.beginSubsegment` / `annotate` / `metadata` / `AwsXRay.endSubsegment`
//! sequence the aspect's `around` advice runs, so real SDK coverage is
//! unaffected by avoiding the aspect indirection.
@test_module
package AwsXRay.XRayTests

import Std.Core
import Std.Testing
import AwsXRay

// ─── Package smoke-test ───────────────────────────────────────────────────────
test "AwsXRay: package can be imported" {
  assertTrue(true, "AwsXRay package import succeeded")
}

// ─── currentSubsegment() outside any active segment/subsegment ──────────────
// Placed first so it exercises the "no active context" fallback path on
// `aws`/`jvm` before any other test in this file opens one (see
// `kernel_currentSubsegment` in src/xray.l).
test "currentSubsegment/annotate/metadata outside any active context do not throw" {
  val seg = AwsXRay.currentSubsegment()
  AwsXRay.annotate(seg, "standalone", "true")
  AwsXRay.metadata(seg, "note", "called outside any begin/end pair")
  assertTrue(true, "currentSubsegment/annotate/metadata completed without throwing")
}

// ─── begin/annotate/metadata/end lifecycle (the sequence Tracing's `around` runs) ──
test "beginSubsegment -> currentSubsegment/annotate/metadata -> endSubsegment do not throw" {
  val seg = AwsXRay.beginSubsegment("handleWork")
  val current = AwsXRay.currentSubsegment()
  AwsXRay.annotate(current, "workId", "abc")
  AwsXRay.metadata(current, "payload", "{\"id\":\"abc\"}")
  AwsXRay.endSubsegment(seg)
  assertTrue(true, "the full subsegment lifecycle completed without throwing")
}

// ─── error-path lifecycle: annotate "error" then end, mirroring Tracing's Err branch ──
test "beginSubsegment -> annotate(error) -> endSubsegment do not throw on the error path" {
  val seg = AwsXRay.beginSubsegment("handleFailingWork")
  AwsXRay.annotate(seg, "error", "boom")
  AwsXRay.endSubsegment(seg)
  assertTrue(true, "the error-path subsegment lifecycle completed without throwing")
}
