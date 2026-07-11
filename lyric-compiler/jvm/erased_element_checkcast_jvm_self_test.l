//! erased_element_checkcast_jvm_self_test.l — CI gate for the "erased
//! collection element" family of JVM backend bugs (#5055, #5381, #5249,
//! #5439, #5444, #5453): indexing a `List[T]`/`slice[T]` receiver whose
//! DECLARED element type `T` is statically known (a bare-name parameter,
//! `val`/`var` local with an explicit annotation, or a bare local bound from
//! a call whose own declared return type is `slice[T]`/`List[T]`) left the
//! erased `java/lang/Object` result of `aaload`/`ArrayList.get` uncast — any
//! further typed use of the element (a `T`-specific instance method, a field
//! read, a numeric intrinsic, interface dispatch) either panicked at compile
//! time (auto-FFI: no matching method on `java.lang.Object`) or crashed at
//! runtime (`ClassCastException`) or failed bytecode verification, depending
//! on the consuming context. `--target dotnet` was never affected (MSIL
//! reifies the element type through its own generic-instantiation model).
//!
//! Fix: `Jvm.Codegen.indexedElemTypeOverride` (jvm/codegen/02_exprs.l)
//! resolves the indexed receiver's recorded element type (from
//! `ctx.varGenericArgs`, populated by `recordDeclaredElemType` at parameter
//! registration and at annotated local bindings, and by `recordVarGenericArgs`
//! for a call-derived binding once `returnTypeGenericArgs`
//! (jvm/codegen/01_types.l) also unwraps a `slice[Elem]` return type) and
//! narrows the `EIndex` result via `applyIndexedElemOverride` — a `checkcast`
//! for a concrete reference type, or a `checkcast` + unbox (+ canonical
//! masked-unsigned re-mask for `Byte`) for a primitive. A same-package
//! interface/protected/opaque element (not `ctorClassFor`-constructible, not
//! `externTypes`-seeded — #5444's class) resolves through the additional
//! `sameTypeExprElemFallback` same-package guess.
//!
//! SCOPE BOUNDARY (see the doc comment on `indexedElemTypeOverride`): this
//! only resolves a BARE NAME receiver. A receiver that is itself a field
//! access (`self.mws[self.idx]`, the exact shape the real #5444 `lyric-web`
//! `MiddlewareChain` repro hits) is NOT covered — that needs a parallel
//! declared-element registry threaded through every `caseFields`-plumbed
//! construction site, out of scope for this fix. `Map[K, V]` VALUES are also
//! NOT covered (`recordDeclaredElemType` deliberately skips `Map`, and the
//! `HashMap.get` `EIndex` arm has no override applied) — extending to Map
//! would need a 2-argument `varGenericArgs` convention (record `[K, V]`,
//! consult index 1) that isn't wired here either.
//!
//! NOT this fix (found while drafting this file, unrelated pre-existing bug,
//! reported separately): a UFCS method declared OUTSIDE a record body
//! (`func Pt.ptArea(self: in Pt): Int { self.a * self.a }`) fails to resolve
//! `self.a` on the JVM backend even with NO indexing involved at all — a
//! plain `Pt(a = 9, b = "z").ptArea()` panics the same way. This is a gap in
//! how a free-standing UFCS method's `self` parameter gets its receiver class
//! registered, orthogonal to collection-element erasure; not fixed here.
//!
//! Run via the native `lyric test` on BOTH targets (dotnet was never broken;
//! this file locks in parity now that JVM is fixed):
//!
//!   lyric test --target dotnet lyric-compiler/jvm/erased_element_checkcast_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/erased_element_checkcast_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.ErasedElementCheckcastJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Fixtures.
// ─────────────────────────────────────────────────────────────────────────────
record Pt {
  a: Int
  b: String
}

interface Shape {
  func area(): Int
}

record Square {
  side: Int
}

impl Shape for Square {
  func area(): Int {
    self.side * self.side
  }
}

func identityLong(v: in Long): Long {
  v
}

// A same-package function returning `slice[Pt]`, mirroring #5439's
// `TranslationStore.availableLocales(): slice[Locale]` shape (an interface
// method there; a free function here is enough to exercise the
// `returnTypeGenericArgs` `TSlice` arm feeding a call-derived, UNANNOTATED
// `val` binding).
func makePoints(): slice[Pt] {
  [Pt(a = 3, b = "x"), Pt(a = 4, b = "y")]
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. List[String] function PARAMETER indexed then a String-specific instance
//    method call directly on the element (#5055 / #5381 headline shape —
//    `Std.Process.buildArgString`'s `args[i].contains(" ")`).
// ─────────────────────────────────────────────────────────────────────────────
func firstContainsSpace(args: in List[String]): Bool {
  val arg = args[0]
  arg.contains(" ")
}

func firstLength(args: in List[String]): Int {
  args[0].length
}

test "List[String] parameter: indexed element narrows for .contains (#5055)" {
  val xs: List[String] = newList()
  xs.add("hello world")
  assertTrue(firstContainsSpace(xs), "'hello world' contains a space")
  val ys: List[String] = newList()
  ys.add("nospaces")
  assertFalse(firstContainsSpace(ys), "'nospaces' has no space")
}

test "List[String] parameter: indexed element narrows for a chained .length (#5381)" {
  val xs: List[String] = newList()
  xs.add("hello")
  assertEqualInt(firstLength(xs), 5, "'hello'.length == 5, resolved directly on the indexed element")
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. slice[T] PARAMETER indexed then chained directly (no intervening typed
//    local) — record field read (#5249 class) and numeric intrinsic (#5453).
// ─────────────────────────────────────────────────────────────────────────────
func firstPointA(pts: in slice[Pt]): Int {
  pts[0].a
}

func firstByteAsInt(bytes: in slice[Byte]): Int {
  bytes[0].toInt()
}

test "slice[Record] parameter: chained field read on the indexed element, no intervening local (#5249)" {
  val pts: slice[Pt] = [Pt(a = 7, b = "hi")]
  assertEqualInt(firstPointA(pts), 7, "pts[0].a reads directly off the indexed element")
}

test "slice[Byte] parameter: chained numeric intrinsic on the indexed element (#5453)" {
  val bs: slice[Byte] = [72u8, 105u8]
  assertEqualInt(firstByteAsInt(bs), 72, "bytes[0].toInt() == 72 ('H'), resolved directly on the indexed element")
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Annotated LOCAL slice[T] (not a parameter): chained field read and a
//    direct call-argument use, both with no intervening typed local — the
//    exact #5249 issue repro shapes.
// ─────────────────────────────────────────────────────────────────────────────
test "slice[Record] local: chained field read on the indexed element (#5249 exact repro)" {
  val xs: slice[Pt] = [Pt(a = 1, b = "x")]
  assertEqualInt(xs[0].a, 1, "xs[0].a reads directly, no intervening `val e: Pt = xs[0]`")
}

test "slice[Long] local: indexed element used directly as a call argument (#5249 exact repro)" {
  val xs: slice[Long] = [10i64, 20i64, 30i64]
  assertEqualLong(identityLong(xs[0]), 10i64, "xs[0] passed directly as a Long call argument")
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. slice[Record] returned from a call, bound to an UNANNOTATED local, then
//    indexed with a chained field read (#5439 class: `List[T].toArray()` /
//    any `slice[T]`-returning call, no explicit `val locs: slice[Locale]`
//    annotation at the binding site — the exact `lyric-i18n`
//    `availableLocales()` repro shape).
// ─────────────────────────────────────────────────────────────────────────────
test "unannotated local bound from a slice[Record]-returning call narrows on index (#5439)" {
  val pts = makePoints()
  assertEqualInt(pts[0].a, 3, "pts[0].a on a call-derived, unannotated slice[Pt] binding")
  assertEqualInt(pts[1].a, 4, "pts[1].a — second element narrows independently")
  assertEqual(pts[0].b, "x", "pts[0].b — String field alongside the Int field")
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. List[Interface] / List[Record-with-method] PARAMETER indexed then a
//    method call on the element (#5444 class, covered sub-case: a bare-name
//    List parameter, not a record-field receiver like `self.mws[self.idx]` —
//    see the module header's scope-boundary note).
// ─────────────────────────────────────────────────────────────────────────────
func firstArea(shapes: in List[Shape]): Int {
  shapes[0].area()
}

func firstSquareArea(squares: in List[Square]): Int {
  squares[0].area()
}

test "List[Interface] parameter: interface dispatch on the indexed element (#5444, bare-local sub-case)" {
  val shapes: List[Shape] = newList()
  shapes.add(Square(side = 5))
  assertEqualInt(firstArea(shapes), 25, "shapes[0].area() dispatches through the interface, not raw Object")
}

test "List[Record] parameter: a record instance method call on the indexed element" {
  val squares: List[Square] = newList()
  squares.add(Square(side = 6))
  assertEqualInt(firstSquareArea(squares), 36, "squares[0].area() resolves the record's own method, not Object")
}
