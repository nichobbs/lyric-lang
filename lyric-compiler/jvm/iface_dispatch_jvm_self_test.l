//! iface_dispatch_jvm_self_test.l — JVM interface-dispatch regression test
//! (#3687, epic #2663).
//!
//! A record implementing a Lyric `interface` and dispatched through an
//! interface-typed binding or parameter previously failed at class load with
//! "Found interface X, but class was expected": interface members were never
//! registered in the `funcSigs` registry, so the call site fell through to
//! the `()Object`-guess `invokevirtual` — and `invokevirtual` against an
//! interface owner is a class-format violation.  `collectFileSigs` now
//! registers each interface member under `<ifaceClass>#<method>` with
//! `isIface = true`, and the J3 M-3 dispatch path emits `invokeinterface`
//! for those sigs.  This module pins the behaviour at runtime.
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.IfaceDispatchSelfTest

import Std.Core
import Std.Testing

pub interface Shape {
  func area(): Int
  func scaled(factor: Int): Int
}

pub record Square {
  side: Int
}

pub record Rect {
  w: Int
  h: Int
}

impl Shape for Square {
  func area(): Int {
    self.side * self.side
  }

  func scaled(factor: Int): Int {
    self.side * self.side * factor
  }
}

impl Shape for Rect {
  func area(): Int {
    self.w * self.h
  }

  func scaled(factor: Int): Int {
    self.w * self.h * factor
  }
}

// Dispatch through an interface-typed parameter — the #3687 repro shape.
func areaThrough(s: in Shape): Int {
  s.area()
}

// Dispatch with an argument, pinning the descriptor/arg-slot path of
// `invokeinterface` (count operand = receiver + args).
func scaledThrough(s: in Shape, factor: Int): Int {
  s.scaled(factor)
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "interface dispatch through an interface-typed parameter" {
  assertEqualInt(areaThrough(Square(side = 3)), 9, "Square through Shape")
  assertEqualInt(areaThrough(Rect(w = 2, h = 5)), 10, "Rect through Shape")
}

test "interface dispatch with an argument" {
  assertEqualInt(scaledThrough(Square(side = 2), 10), 40, "Square scaled through Shape")
  assertEqualInt(scaledThrough(Rect(w = 3, h = 3), 2), 18, "Rect scaled through Shape")
}

test "interface dispatch on a direct record value still works" {
  val sq = Square(side = 4)
  assertEqualInt(sq.area(), 16, "direct record method call unaffected")
}

// ── #5607: explicit-self (D037) interface methods ─────────────────────────────
// An interface method declared with an explicit `self: in Self` receiver got
// `self` included in the JVM interface method DESCRIPTOR, so every
// `invokeinterface` call site arity-mismatched — VerifyError "Attempt to pop
// empty stack" in the caller.  The canonical no-self spelling above was
// unaffected.  `stripLeadingSelfParam` now applies at interface registration
// (`registerIfaceSig`), abstract-method emission, and `lowerImplMethod`,
// mirroring the MSIL fix's placement discipline (D-progress-657).
pub interface SelfNamer {
  func nameOf(self: in Self): String
  func tagged(self: in Self, tag: String): String
}

pub record SelfNamed {
  label: String
}

impl SelfNamer for SelfNamed {
  func nameOf(self: in SelfNamed): String {
    self.label
  }

  func tagged(self: in SelfNamed, tag: String): String {
    self.label + ":" + tag
  }
}

func nameThrough(n: in SelfNamer): String {
  n.nameOf()
}

test "explicit-self interface dispatch through an interface-typed binding (#5607)" {
  val n: SelfNamer = SelfNamed(label = "named")
  assertEqual(n.nameOf(), "named", "explicit-self nameOf through binding")
}

test "explicit-self interface dispatch with an argument (#5607)" {
  val n: SelfNamer = SelfNamed(label = "x")
  assertEqual(n.tagged("t"), "x:t", "explicit-self descriptor keeps only real params")
  assertEqual(nameThrough(SelfNamed(label = "via")), "via", "explicit-self through param")
}

// The async form of the same shape (the MSIL twin lives in
// async_sm_self_test.l ok 58-61, dotnet-only per #2736).
pub interface SelfFetcher {
  async func fetchSelf(self: in Self, q: in String): String
}

pub record SelfFetch {
}

impl SelfFetcher for SelfFetch {
  async func fetchSelf(self: in SelfFetch, q: in String): String {
    q + "?"
  }
}

test "explicit-self async interface dispatch (#5607)" {
  val c: SelfFetcher = SelfFetch()
  val r = await c.fetchSelf("yo")
  assertEqual(r, "yo?", "explicit-self async dispatch")
}

// #5931: `impl <ExternInterface> for Record` with a `slice[ExternType]`
// parameter previously erased the array element to `Object` regardless of
// the interface's real element type (`holderAwareParamTypes`'s `erase` arm
// fell through to the generic slice erasure), so the emitted class's method
// descriptor did not match the interface's — the JDK's own `Callback[]`
// erased to `[Ljava/lang/Object;` here, a binary-incompatible override the
// JVM accepts at class load but rejects at `invokeinterface` dispatch time
// with `AbstractMethodError` (verified with `javap`: the fix changes the
// emitted descriptor from `handle(Ljava/lang/Object;)V` to the real
// `handle([Ljavax/security/auth/callback/Callback;)V`). A Lyric-authored
// call site through an interface-TYPED extern receiver (`h: in
// JCallbackHandler`) resolves via auto-FFI rather than this impl's own
// registered signature — a separate, pre-existing auto-FFI limitation this
// fix does not touch — so this test instead pins the descriptor-affecting
// side directly: construction and a direct call on the CONCRETE record
// compile and run (mirroring `ffi_iface_impl_jvm_self_test.l`'s pattern),
// which is exactly what silently broke while codegen was still computing
// `Object[]` internally for the slice-typed param under generic erasure.
extern type JCallbackHandler = "javax.security.auth.callback.CallbackHandler"

extern type JCallback = "javax.security.auth.callback.Callback"

record SliceIfaceHandler {
  tag: Int
}

impl JCallbackHandler for SliceIfaceHandler {
  func handle(callbacks: in slice[JCallback]): Unit {
    ()
  }
}

test "impl ExternInterface for Record with a slice[ExternType] param compiles and dispatches on the concrete type (#5931)" {
  val h = SliceIfaceHandler(tag = 9)
  val cbs: slice[JCallback] = []
  h.handle(cbs)
  assertEqualInt(h.tag, 9, "SliceIfaceHandler field still readable after the slice-param method call")
}

// #6970 (review follow-up on #5931): the parameter-side test above pins
// `implParamTypesToJvm`; this pins the sibling `retTy` code path in
// `lowerImplMethod`, which narrows a `slice[ExternType]` RETURN value the
// same way. Uses the exact motivating example from the original #5931
// report: `X509TrustManager.getAcceptedIssuers(): slice[X509Certificate]`.
extern type JX509Certificate = "java.security.cert.X509Certificate"

extern type JX509TrustManager = "javax.net.ssl.X509TrustManager"

record SliceIfaceTrustManager {
  tag: Int
}

impl JX509TrustManager for SliceIfaceTrustManager {
  func checkClientTrusted(chain: in slice[JX509Certificate], authType: in String): Unit {
    ()
  }

  func checkServerTrusted(chain: in slice[JX509Certificate], authType: in String): Unit {
    ()
  }

  func getAcceptedIssuers(): slice[JX509Certificate] {
    []
  }
}

test "impl ExternInterface for Record with a slice[ExternType] return compiles and dispatches on the concrete type (#5931 / #6970)" {
  val tm = SliceIfaceTrustManager(tag = 3)
  val issuers = tm.getAcceptedIssuers()
  assertEqualInt(issuers.length, 0, "getAcceptedIssuers returns the empty slice built in the impl body")
  assertEqualInt(tm.tag, 3, "SliceIfaceTrustManager field still readable after the slice-return method call")
}

// #6977 (review follow-up on #5931/#6970): `implTypeExprToJvm`'s own doc
// comment says a PRIMITIVE slice element needs the real primitive array too
// ("not just an extern one"), but the type-resolution side (`TSlice(elem) ->
// JArray(elem = implTypeExprToJvm(elem, ...))`) was already correct — the
// gap was on the CODEGEN side: `coerceArgTo`'s `ArrayList` -> array
// conversion always used the no-arg `toArray()` overload (erasing to
// `Object[]`), which is not assignable where a `byte[]` (or any other
// primitive array) is required by the narrowed descriptor. Uses a real JDK
// interface with a `byte[]`-returning method: `java.security.Key.
// getEncoded()`.
extern type JKey = "java.security.Key"

record SliceIfacePrimitiveKey {
  tag: Int
}

impl JKey for SliceIfacePrimitiveKey {
  func getAlgorithm(): String {
    "NONE"
  }

  func getFormat(): String {
    "RAW"
  }

  func getEncoded(): slice[Byte] {
    [1.toByte(), 2.toByte(), 3.toByte()]
  }
}

test "impl ExternInterface for Record with a slice[Byte] (primitive-element) return compiles and dispatches on the concrete type (#5931 / #6977)" {
  val k = SliceIfacePrimitiveKey(tag = 7)
  val encoded = k.getEncoded()
  assertEqualInt(encoded.length, 3, "getEncoded returns the 3-byte slice built in the impl body")
  assertEqualInt(encoded[0].toInt(), 1, "first byte round-trips")
  assertEqualInt(encoded[1].toInt(), 2, "second byte round-trips")
  assertEqualInt(encoded[2].toInt(), 3, "third byte round-trips")
  assertEqualInt(k.tag, 7, "SliceIfacePrimitiveKey field still readable after the primitive-slice-return method call")
}
