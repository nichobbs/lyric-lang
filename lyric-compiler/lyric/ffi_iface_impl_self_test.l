//! ffi_iface_impl_self_test.l — executable regression test for D105,
//! Phase 1: a Lyric record may declare `impl <ExternInterface> for …`
//! where the interface name was brought into scope via `extern type`
//! (or `import extern`).  The MSIL backend resolves the interface
//! through `cctx.externTypeNames` to the CLR FQN
//! (e.g. `System.IDisposable`), reserves the TypeRef row via
//! `internFfiTypeRefNested`, and `lowerMImpl` emits an `InterfaceImpl`
//! row pointing at that TypeRef.
//!
//! Before D105, `implIfaceNameMsil` qualified single-segment iface
//! names with the local package, so `impl IDisposable for MyRes`
//! produced an iface name of `<pkg>.IDisposable`, no TypeRef row was
//! found, and `lowerMImpl` panicked.  This test exercises the codegen
//! path end-to-end — its mere successful compilation is the regression
//! guard.  The Dispose method is invoked directly to confirm the
//! impl-method body is reachable; full CLR-side interface-dispatch
//! verification (widening a Lyric record to an extern-interface typed
//! variable, passing to a C#-side consumer) requires the deferred
//! type-checker widening work also noted in D105.
@test_module
package Lyric.FfiIfaceImplSelfTest

import Std.Core
import Std.Testing

extern type IDisposable = "System.IDisposable"

record Resource {
  tag: Int
}

impl IDisposable for Resource {
  func Dispose(): Unit {
    // Body is irrelevant; the regression is whether the codegen
    // path (TypeRef reservation + InterfaceImpl row emission) runs
    // without panicking when the iface name is a single-segment
    // alias of an external CLR type.
  }
}

test "impl ExternInterface for Record compiles, and the impl method is callable" {
  val r = Resource(tag = 7)
  r.Dispose()
  assertEqualInt(r.tag, 7, "Resource fields still readable after Dispose runs")
}

// A second `impl … for …` block in the same file pins that the
// per-impl TypeRef reservation doesn't trip a "duplicate row" path —
// `internFfiTypeRefNested` caches by FQN, so the second impl reuses
// the first impl's TypeRef row rather than allocating a fresh one.
record OtherResource {
  count: Int
}

impl IDisposable for OtherResource {
  func Dispose(): Unit {
  }
}

test "second `impl IDisposable for …` reuses the cached TypeRef row" {
  val r = OtherResource(count = 0)
  r.Dispose()
  assertEqualInt(r.count, 0, "OtherResource fields still readable")
}
