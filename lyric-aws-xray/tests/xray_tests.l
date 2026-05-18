// tests/xray_tests.l — tests for the pure-Lyric surface of lyric-aws-xray.
//
// The AwsXRay package surface is almost entirely kernel-backed: SubsegmentHandle
// is an opaque type, and currentSubsegment(), annotate(), and metadata() all
// require the X-Ray SDK.  This file serves as an import smoke-test and covers
// the structural presence of the package.
// Live tracing and annotation functions require an active Lambda invocation with
// X-Ray active tracing enabled and are not tested here.

@test_module
package AwsXRay.XRayTests

import Std.Core
import Std.Testing
import AwsXRay

// ─── Package smoke-test ───────────────────────────────────────────────────────

test "AwsXRay: package can be imported" {
  assertTrue(true, "AwsXRay package import succeeded")
}
