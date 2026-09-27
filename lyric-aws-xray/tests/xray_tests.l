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
import Std.String as Str
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

// ─── isValidAnnotationKey ─────────────────────────────────────────────────────
test "isValidAnnotationKey: accepts alphanumeric and underscore keys" {
  assertTrue(AwsXRay.isValidAnnotationKey("orderId"), "plain letters accepted")
  assertTrue(AwsXRay.isValidAnnotationKey("order_id_123"), "letters, digits, underscore accepted")
  assertTrue(AwsXRay.isValidAnnotationKey("A"), "single character accepted")
}

test "isValidAnnotationKey: rejects an empty key" {
  assertFalse(AwsXRay.isValidAnnotationKey(""), "empty key rejected")
}

test "isValidAnnotationKey: rejects a key over 500 characters" {
  val tooLong = Str.repeat("a", 501)
  assertFalse(AwsXRay.isValidAnnotationKey(tooLong), "501-character key rejected")
}

test "isValidAnnotationKey: accepts a key of exactly 500 characters" {
  val maxLen = Str.repeat("a", 500)
  assertTrue(AwsXRay.isValidAnnotationKey(maxLen), "500-character key accepted")
}

test "isValidAnnotationKey: rejects keys with disallowed characters" {
  assertFalse(AwsXRay.isValidAnnotationKey("order id"), "space rejected")
  assertFalse(AwsXRay.isValidAnnotationKey("order.id"), "dot rejected")
  assertFalse(AwsXRay.isValidAnnotationKey("order-id"), "hyphen rejected")
}

// ─── annotate: precondition violation on an invalid key ──────────────────────
func annotateWithInvalidKey(): Unit {
  val seg = AwsXRay.currentSubsegment()
  AwsXRay.annotate(seg, "not valid!", "value")
}

test "annotate: panics on a key that fails isValidAnnotationKey" {
  assertPanics("annotate with an invalid key", annotateWithInvalidKey)
}

func annotateWithEmptyKey(): Unit {
  val seg = AwsXRay.currentSubsegment()
  AwsXRay.annotate(seg, "", "value")
}

test "annotate: panics on an empty key" {
  assertPanics("annotate with an empty key", annotateWithEmptyKey)
}

// ─── beginSubsegment: length preconditions ────────────────────────────────────
func beginSubsegmentWithEmptyName(): Unit {
  val seg = AwsXRay.beginSubsegment("")
}

test "beginSubsegment: panics on an empty name" {
  assertPanics("beginSubsegment with an empty name", beginSubsegmentWithEmptyName)
}

func beginSubsegmentWithTooLongName(): Unit {
  val seg = AwsXRay.beginSubsegment(Str.repeat("n", 201))
}

test "beginSubsegment: panics on a name over 200 characters" {
  assertPanics("beginSubsegment with a 201-character name", beginSubsegmentWithTooLongName)
}

test "beginSubsegment: accepts a name of exactly 200 characters" {
  val seg = AwsXRay.beginSubsegment(Str.repeat("n", 200))
  AwsXRay.endSubsegment(seg)
  assertTrue(true, "200-character name accepted")
}

// ─── sanitizeAnnotation: byte cap and surrogate-pair-safe truncation ─────────
test "sanitizeAnnotation: strings under the 1024-byte cap pass through unchanged" {
  val s = "hello world"
  assertEqual(AwsXRay.sanitizeAnnotation(s), s, "short ASCII string is unchanged")
}

test "sanitizeAnnotation: truncates plain ASCII to at most 1024 characters" {
  val long = Str.repeat("a", 2000)
  val sanitized = AwsXRay.sanitizeAnnotation(long)
  assertEqualInt(sanitized.length, 1024, "1024 single-byte chars fill the 1024-byte budget exactly")
}

// Padding is chosen so the loop admits the emoji's high surrogate (byteCount
// 1020 + 3 = 1023 <= 1024) but not its low surrogate (1023 + 3 = 1026 > 1024),
// the exact scenario that used to split the pair.
func buildSurrogateSplitCandidate(): String {
  return Str.repeat("a", 1020) + "😀"
}

test "sanitizeAnnotation: never cuts between a high and low surrogate" {
  val input = buildSurrogateSplitCandidate()
  val sanitized = AwsXRay.sanitizeAnnotation(input)
  assertEqualInt(sanitized.length, 1020, "the orphaned high surrogate is dropped, not emitted alone")
  assertEqual(sanitized, Str.repeat("a", 1020), "output is exactly the padding, with no partial surrogate")
}
