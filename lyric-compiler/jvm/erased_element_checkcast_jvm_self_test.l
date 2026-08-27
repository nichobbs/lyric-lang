//! erased_element_checkcast_jvm_self_test.l — CI gate for the "erased
//! collection element" family of JVM backend bugs (#5055, #5381, #5249,
//! #5439, #5444, #5453, #5451): indexing a `List[T]`/`slice[T]`/`Map[K, V]`
//! receiver whose DECLARED element/value type is statically known (a
//! bare-name parameter, `val`/`var` local with an explicit annotation, or a
//! bare local bound from a call whose own declared return type carries the
//! same shape) left the erased `java/lang/Object` result of `aaload`/
//! `ArrayList.get`/`HashMap.get` uncast — any further typed use of the
//! element (a `T`-specific instance method, a field read, a numeric
//! intrinsic, interface dispatch) either panicked at compile time (auto-FFI:
//! no matching method on `java.lang.Object`) or crashed at runtime
//! (`ClassCastException`, possibly against an entirely unrelated type, #5451)
//! or failed bytecode verification, depending on the consuming context.
//! `--target dotnet` was never affected (MSIL reifies the element type
//! through its own generic-instantiation model).
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
//! FIELD receivers (#5444, section 6 below): a receiver that is itself a
//! field access (`self.mws[self.idx]`, the exact shape the real #5444
//! `lyric-web` `MiddlewareChain` repro hits) resolves through the
//! `elem:<class>#<field>` funcSigs registry (`registerFieldElemSig`,
//! jvm/codegen/06_items.l): record/protected/opaque slice/List fields
//! register their declared element type at signature collection, and
//! `indexedElemTypeOverride`'s `EMember` / bare-self-field arms consult it
//! with the base's statically-resolved class (`staticBaseClass`).
//!
//! `Map[K, V]` VALUES (#5451, section 7 below) are covered the same way: a
//! `Map` field's `V` registers under the identical `elem:<class>#<field>`
//! key (`registerFieldElemSig`'s new `Map`-with-2-args arm records only `V`
//! at index 1 — `K` is never consulted by a value read); a bare-name/
//! call-derived `Map[K, V]` receiver records the full `[K, V]` pair into
//! `ctx.varGenericArgs` (`recordDeclaredElemType`'s new `Map` arm, and
//! `returnTypeGenericArgs`'s existing generic `TGenericApp` arm for the
//! call-derived path), and `indexedElemTypeOverride`'s general arm consults
//! index 1 for a 2-element entry (index 0 remains the 1-element
//! slice/List convention). The `HashMap.get` `EIndex` arm now applies the
//! resolved override via `applyIndexedElemOverride`, exactly like the
//! `ArrayList.get`/array arms already did — before this fix it discarded the
//! override and always returned an unconditional, un-narrowed erased
//! `Object`, which meant a Map[String, Record] field sharing a JVM bundle
//! with an unrelated Map[String, Long] instantiation could — once ANY
//! downstream consumer of the erased Object guessed a concrete type from
//! some other coarser source — surface as a `ClassCastException` naming an
//! entirely unrelated class (the `lyric-session` `InProcessSessionStore`
//! repro: a `Map[String, SessionData]` field's `self.sessions[id]` read
//! crashing next to a sibling `ttlSeconds: Long` field).
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
//    method call on the element (#5444 class, bare-name sub-case).
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

// ─────────────────────────────────────────────────────────────────────────────
// 6. FIELD receivers (#5444, the real lyric-web `MiddlewareChain` shape): the
//    indexed slice/List lives in a record FIELD and is read as
//    `self.f[self.idx]` inside an impl method (recursive chain, interface
//    dispatch on the element), as `local.f[i]` off a typed local, and as
//    `holder.inner.f[i]` through a chained field access.  Resolved via the
//    `elem:<class>#<field>` registry (`registerFieldElemSig`) +
//    `staticBaseClass`, not the bare-name `varGenericArgs` path sections 1-5
//    exercise.
// ─────────────────────────────────────────────────────────────────────────────
record ShapeChain {
  shapes: slice[Shape]
  idx: Int
}

impl Shape for ShapeChain {
  func area(): Int {
    if self.idx >= self.shapes.length {
      return 0
    }
    val s = self.shapes[self.idx]
    val rest = ShapeChain(shapes = self.shapes, idx = self.idx + 1)
    return s.area() + rest.area()
  }
}

record ShapeBox {
  items: List[Shape]
}

record BoxHolder {
  inner: ShapeBox
}

record SquareRow {
  row: slice[Square]
  func firstArea(): Int {
    return self.row[0].area()
  }
}

test "slice[Interface] record field: self.f[self.idx] chains interface dispatch (#5444 exact MiddlewareChain shape)" {
  // Element-wise upcast: the checker does not widen a `slice[Square]`
  // literal to `slice[Shape]` at the binding (T0060), so bind each element
  // as `Shape` first — the same spelling lyric-web's middleware setup uses.
  val s2: Shape = Square(side = 2)
  val s3: Shape = Square(side = 3)
  val shapes: slice[Shape] = [s2, s3]
  val chain = ShapeChain(shapes = shapes, idx = 0)
  assertEqualInt(chain.area(), 13, "4 + 9 summed by walking self.shapes[self.idx] recursively")
}

test "List[Interface] record field: local.f[i] narrows for interface dispatch (#5444)" {
  val items: List[Shape] = newList()
  items.add(Square(side = 4))
  val box = ShapeBox(items = items)
  assertEqualInt(box.items[0].area(), 16, "box.items[0].area() dispatches through the interface")
}

test "chained field access: holder.inner.f[i] narrows for interface dispatch (#5444)" {
  val items: List[Shape] = newList()
  items.add(Square(side = 7))
  val holder = BoxHolder(inner = ShapeBox(items = items))
  assertEqualInt(holder.inner.items[0].area(), 49, "two-step field chain resolves the element class")
}

test "slice[Record] record field: self.f[0] inside a record method calls the element's own method (#5444)" {
  val srow = SquareRow(row = [Square(side = 8)])
  assertEqualInt(srow.firstArea(), 64, "self.row[0].area() inside a record method")
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Map[K, V] VALUES (#5451, the `lyric-session` `InProcessSessionStore`
//    shape): a `Map`-typed field/local/call-return's VALUE narrows on
//    `m[k]`, and does not resolve against an unrelated Map instantiation of
//    a different value type sharing the same JVM compilation unit.
// ─────────────────────────────────────────────────────────────────────────────
record MultiValueStore {
  var counts: Map[String, Long]
  var points: Map[String, Pt]
}

interface Multi {
  func setCount(id: in String, n: in Long): Unit
  func getCount(id: in String): Long
  func setPoint(id: in String, p: in Pt): Unit
  func getPointA(id: in String): Int
}

impl Multi for MultiValueStore {
  func setCount(id: in String, n: in Long): Unit {
    self.counts[id] = n
  }

  func getCount(id: in String): Long {
    self.counts[id]
  }

  func setPoint(id: in String, p: in Pt): Unit {
    self.points[id] = p
  }

  func getPointA(id: in String): Int {
    self.points[id].a
  }
}

func makeStringPtMap(): Map[String, Pt] {
  val m: Map[String, Pt] = newMap()
  m["only"] = Pt(a = 33, b = "thirty-three")
  m
}

test "record with two sibling Map[K, V] fields of different value types: self.field[key] reads narrow independently inside methods (#5451, the InProcessSessionStore shape)" {
  val mvs = MultiValueStore(counts = newMap(), points = newMap())
  mvs.setCount("x", 42i64)
  mvs.setPoint("p", Pt(a = 5, b = "five"))
  assertEqualLong(mvs.getCount("x"), 42i64, "self.counts[id] on a Map[String, Long] field narrows to Long")
  assertEqualInt(
    mvs.getPointA("p"),
    5,
    "self.points[id].a on a sibling Map[String, Record] field narrows to the record, not Long"
  )
}

test "Map[String, Record] bare-name local: an explicit declared-type annotation narrows the value on index (#5451)" {
  val m: Map[String, Pt] = newMap()
  m["k"] = Pt(a = 21, b = "twenty-one")
  val pt = m["k"]
  assertEqualInt(pt.a, 21, "an annotated Map[String, Record] local's indexed value narrows via recordDeclaredElemType")
}

test "Map[String, Record] bare-name local bound from a call: the call-derived declared return narrows the value on index (#5451)" {
  val m = makeStringPtMap()
  assertEqualInt(
    m["only"].a,
    33,
    "a call-derived, unannotated Map[String, Pt] binding narrows via returnTypeGenericArgs, no intervening `val e: Pt = m[\"only\"]`"
  )
}
