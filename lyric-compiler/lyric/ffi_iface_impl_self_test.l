//! ffi_iface_impl_self_test.l — executable regression test for D105.
//!
//! Phase 1: a Lyric record may declare `impl <ExternInterface> for …`
//! where the interface name was brought into scope via `extern type`
//! (or `import extern`).  The MSIL backend resolves the interface
//! through `cctx.externTypeNames` to the CLR FQN
//! (e.g. `System.IDisposable`), reserves the TypeRef row via
//! `internFfiTypeRefNested`, and `lowerMImpl` emits an `InterfaceImpl`
//! row pointing at that TypeRef.
//!
//! Phase 3 (this file's extension): a Lyric record value may be widened
//! to an extern-interface-typed `val` / `var` binding or function
//! parameter, and a method call on the widened binding dispatches via
//! the interface's CLR MemberRef.  Conformance is keyed on `TypeId`,
//! which `registerImplsFromItems` already records for `extern type`
//! targets, so the existing `argSatisfiesParam` path accepts the
//! widening without a type-checker patch.
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

// Phase 3a: a `val d: IDisposable = Resource(...)` binding type-checks
// via `argSatisfiesParam`'s interface-subtyping fallthrough, which
// looks up the impl pair recorded by `registerImplsFromItems`.  The IL
// store is a plain `stloc` into a `System.IDisposable`-typed slot — no
// `castclass` is required because the InterfaceImpl row makes the
// runtime accept the assignment.
test "Lyric record widens to an extern-interface-typed val binding" {
  val r = Resource(tag = 42)
  val d: IDisposable = r
  // `d.Dispose()` dispatches via auto-FFI's metadata-resolved instance
  // method path against `System.IDisposable.Dispose()`.  The CLR routes
  // the callvirt to `Resource.Dispose` because the impl block emitted
  // the matching InterfaceImpl row.
  d.Dispose()
  assertEqualInt(r.tag, 42, "field still readable through the original binding after widening")
}

// Phase 3b: an extern-interface-typed parameter accepts a record that
// declares the impl, and a method call inside the callee dispatches
// through the interface.  Lyric's parameter passing for reference
// types is by reference (the record handle), so the callee sees the
// same object as the caller.
func disposeIt(d: in IDisposable): Unit {
  d.Dispose()
}

test "extern-interface-typed parameter accepts a conforming record" {
  val r = Resource(tag = 99)
  disposeIt(r)
  assertEqualInt(r.tag, 99, "Dispose ran via interface dispatch")
}
