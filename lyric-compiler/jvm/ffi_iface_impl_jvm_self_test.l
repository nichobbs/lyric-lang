//! ffi_iface_impl_jvm_self_test.l — JVM regression test for `impl <ExternInterface>
//! for Record` (the JVM analog of D105 / docs/51, which shipped MSIL-only).
//!
//! `constraintRefToJvmClass` (jvm/codegen/06_items.l) previously resolved every
//! single-segment `impl` interface name to the in-package `<pkg>/<Name>` guess,
//! ignoring the file's `extern type` alias table entirely.  `impl <ExternInterface>
//! for Record` therefore emitted a JVM `implements <pkg>/<IfaceName>` entry
//! pointing at a class that does not exist, faulting with `NoClassDefFoundError`
//! at class-load time — the JVM interface list never referenced the real JDK
//! interface at all.  Separately, `holderAwareParamTypes`'s `erase` branch
//! (used for impl-method params) and `lowerImplMethod`'s return-type resolution
//! both ignored the `externTypes` map they were passed, so even a correctly
//! resolved interface would degrade a `String`/`Bool` extern-interface method
//! parameter or return type to the in-package guess instead of the real JVM
//! type.
//!
//! This suite pins all three fixes using `java.io.FilenameFilter` (a real,
//! always-available two-method-signature JDK interface — `boolean
//! accept(File dir, String name)` — needing no Maven dependency): the fact
//! that this program compiles, the class loads, and the impl method
//! dispatches correctly through the interface exercises the interface-name
//! resolution; the correct `true`/`false` results for non-generic
//! `File`/`String`/`Bool` params exercise the param/return-type resolution.
//!
//! Run in CI via native `lyric test --target jvm` (compiles the module
//! in-process through the self-hosted `Jvm.Bridge` `compileToJarBundled` and
//! runs it under `java`).  Imports only `Std.*`.
@test_module
package Jvm.FfiIfaceImplJvmSelfTest

import Std.Core
import Std.Testing

extern type JFilenameFilter = "java.io.FilenameFilter"

extern type JFile = "java.io.File"

record AcceptNonEmptyFilter {
  tag: Int
}

impl JFilenameFilter for AcceptNonEmptyFilter {
  func accept(dir: in JFile, name: in String): Bool {
    name.length > 0
  }
}

test "impl ExternInterface for Record resolves the real JVM interface name and typed params/return on JVM" {
  val f = AcceptNonEmptyFilter(tag = 7)
  val dir = JFile.new(".")
  assertTrue(f.accept(dir, "hello.txt"), "non-empty name accepted")
  assertTrue(not f.accept(dir, ""), "empty name rejected")
  assertEqualInt(f.tag, 7, "record field still readable after interface dispatch")
}

// A second `impl … for …` block for the same extern interface in the same
// file pins that the per-impl class-name resolution doesn't collide.
record RejectAllFilter {
  count: Int
}

impl JFilenameFilter for RejectAllFilter {
  func accept(dir: in JFile, name: in String): Bool {
    false
  }
}

test "second impl of the same extern interface resolves independently" {
  val f = RejectAllFilter(count = 0)
  val dir = JFile.new(".")
  assertTrue(not f.accept(dir, "anything"), "RejectAllFilter always rejects")
  assertEqualInt(f.count, 0, "RejectAllFilter field still readable")
}

// A GENERIC extern interface erases its type parameter in the descriptor the
// JVM dispatches through: `Comparator<T>.compare(T, T)` is `compare(Object,
// Object)I`, while the impl method spells `String`.  The impl method's own
// descriptor is `compare(String, String)I`, which does not override the slot,
// so a call through the interface failed with `AbstractMethodError`.  The
// backend now reads the slot's descriptor from the interface's class metadata
// and emits the synthetic bridge javac emits (cast each narrowed parameter,
// forward to the real method) — lyric-grpc's `MethodDescriptor.Marshaller<T>`
// needs exactly this.
extern type JComparator = "java.util.Comparator"

record ByLength {
  tag: Int
}

impl JComparator for ByLength {
  func compare(a: in String, b: in String): Int {
    a.length - b.length
  }
}

test "impl <generic ExternInterface> narrowing an erased parameter is reachable through the interface" {
  val cmp: JComparator = ByLength(tag = 1)
  assertTrue(cmp.compare("aaa", "b") > 0, "longer string sorts after the shorter one through the interface")
  assertTrue(cmp.compare("b", "aaa") < 0, "and the reverse")
  assertEqualInt(cmp.compare("xy", "zw"), 0, "equal lengths compare equal")
}
