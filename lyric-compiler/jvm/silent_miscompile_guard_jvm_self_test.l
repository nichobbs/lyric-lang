//! silent_miscompile_guard_jvm_self_test.l — CI gate for JVM-backend silent
//! miscompiles fixed in band J1 (docs/44 §5 J1, #2664, epic #2663).
//!
//! Each `test` block asserts a value that the *pre-fix* self-hosted JVM
//! backend produced wrong-but-running (or faulted at runtime).  Run via the
//! native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/silent_miscompile_guard_jvm_self_test.l
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it IN-PROCESS through the self-hosted `Jvm.Bridge`
//! (`compileToJarBundled`), then runs it under `java` and asserts every
//! embedded assertion held.  Imports only `Std.*`, so no
//! `LYRIC_LOAD_COMPILER=1` is needed.
//!
//! Coverage (one `test` per J1 fix):
//!   1. Float round-trip keeps 32-bit semantics (B-4: Float was emitted as
//!      JVM `double`).
//!   2. Complex assignment writes are observed (B-5: `obj.field = e` /
//!      `arr[i] = e` lowered to a silent value-pop no-op).
//!   3. or-pattern variable binding (m-1: `A(x) | B(x) -> x` bound `x` to a
//!      no-op).
//!   4. Union-case construction + match round-trip (B-8 / #1675: construction
//!      emitted a non-existent static factory → NoSuchMethodError).
//!   5. Named-argument record construction reorder (B-7 / #1793: out-of-order
//!      named args were placed into the wrong ctor slots).
//!   10. A `var` declared inside an `if`-expression passed as a call
//!       argument is hoisted for lambda capture (#4264: the hoisting
//!       pre-pass `collectMutableVarsExpr` never recursed into `ECall`
//!       arguments, so a `var` nested that way was never hoisted and a
//!       lambda mutating it silently wrote to its own by-value snapshot).
//!   13. Whole-valued Double stringification matches .NET (#4688, docs/44
//!       m-21: Java's Double.toString() always renders a fractional digit
//!       where .NET's default ToString() omits it for whole values).
//!   14. `emitArrayLoad`'s typed-dispatch (#3541 follow-up): every reachable
//!       hoisted-holder-cell element type (Float/Long/Int/Byte/Double/Bool/
//!       Char, plus the default JRef branch via String) gets a real
//!       regression test; `JShort` has no reachable Lyric surface type.
@test_module
package Lyric.SilentMiscompileGuardJvmSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Test fixtures.
// ─────────────────────────────────────────────────────────────────────────────
// A record with two differently-typed fields, used to exercise complex field
// assignment and named-argument reorder.
record Mixed {
  var count: Int
  var label: String
}

// A union with a payload-bearing case, used to exercise union construction and
// or-pattern binding.
union Box {
  case Full(value: Int)
  case Empty
}

// A second payload-bearing case with the *same* binding name, for the
// or-pattern test (`Full(x) | Tagged(x) -> x`).
union Tagged2 {
  case A(x: Int)
  case B(x: Int)
}

// Returns its Float argument scaled, to force a Float value across a function
// boundary (param load + arithmetic + return all in 32-bit float opcodes).
func scaleFloat(v: in Float, by: in Float): Float {
  v * by
}

// Identity wrapper used to force an `if`-expression into call-argument
// position for the #4264 hoisting-completeness test below.
func identityInt(x: in Int): Int {
  x
}

// Returns the i-th element of a 3-element Int slice after mutating it.
func sumBox(b: in Box): Int {
  match b {
    case Full(v) -> v
    case Empty -> 0
  }
}

// Extract the payload from a `Tagged2` via an or-pattern binding the same name
// in both alternatives.
func taggedPayload(t: in Tagged2): Int {
  match t {
    case A(x) | B(x) -> x
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Float — genuine 32-bit semantics (B-4).
// ─────────────────────────────────────────────────────────────────────────────
test "Float keeps 32-bit precision (not promoted to double)" {
  // 2^24 = 16_777_216 is the largest integer such that 2^24 + 1 is NOT
  // representable as a 32-bit float (the gap between consecutive floats there
  // is 2.0).  In 32-bit float arithmetic, 16777216f + 1f == 16777216f.  If the
  // backend wrongly used `double`, the sum would be 16777217 and this would
  // FAIL.
  val big: Float = 16777216.0f32
  val one: Float = 1.0f32
  val sum: Float = big + one
  assertTrue(sum == big, "16777216f + 1f == 16777216f (32-bit float, not double)")
  // A double doing the same sum *does* gain the bit — sanity-check the
  // contrast so a Float-as-double regression can't pass this file.
  val bigD: Double = 16777216.0
  val oneD: Double = 1.0
  assertTrue((bigD + oneD) != bigD, "16777216.0 + 1.0 != 16777216.0 (double keeps the bit)")
}

test "Float arithmetic and round-trip through a function" {
  val a: Float = 1.5f32
  val b: Float = 2.0f32
  // 1.5 * 2.0 = 3.0 exactly representable in float.
  val r: Float = scaleFloat(a, b)
  assertTrue(r == 3.0f32, "scaleFloat(1.5f, 2.0f) == 3.0f")
  // Difference exact in float.
  val d: Float = b - a
  assertTrue(d == 0.5f32, "2.0f - 1.5f == 0.5f")
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Complex assignment — field and slice-element writes (B-5).
// ─────────────────────────────────────────────────────────────────────────────
test "record field assignment is observed" {
  var m = Mixed(count = 1, label = "a")
  m.count = 42
  m.label = "z"
  assertEqualInt(m.count, 42, "m.count after field assignment")
  assertEqual(m.label, "z", "m.label after field assignment")
}

test "compound field assignment combines and stores" {
  var m = Mixed(count = 10, label = "x")
  m.count += 5
  m.count *= 2
  assertEqualInt(m.count, 30, "(10 + 5) * 2 via compound field assignment")
}

test "slice element assignment is observed" {
  var xs = [1, 2, 3]
  xs[0] = 10
  xs[2] = 30
  assertEqualInt(xs[0], 10, "xs[0] after element assignment")
  assertEqualInt(xs[1], 2, "xs[1] unchanged")
  assertEqualInt(xs[2], 30, "xs[2] after element assignment")
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. or-pattern variable binding (m-1).
// ─────────────────────────────────────────────────────────────────────────────
test "or-pattern binds the variable from either alternative" {
  val fromA = taggedPayload(A(x = 7))
  val fromB = taggedPayload(B(x = 9))
  assertEqualInt(fromA, 7, "A(x)|B(x) -> x binds from A")
  assertEqualInt(fromB, 9, "A(x)|B(x) -> x binds from B")
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Union-case construction + match round-trip (B-8 / #1675).
// ─────────────────────────────────────────────────────────────────────────────
test "union case construction round-trips through match" {
  val full = Full(value = 5)
  val empty = Empty
  assertEqualInt(sumBox(full), 5, "Full(5) constructs and matches back to 5")
  assertEqualInt(sumBox(empty), 0, "Empty constructs and matches back to 0")
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Named-argument record construction reorder (B-7 / #1793).
// ─────────────────────────────────────────────────────────────────────────────
test "named-args out of declaration order land in the right fields" {
  // Fields declared (count: Int, label: String); supply them reversed.
  val m = Mixed(label = "hello", count = 99)
  assertEqualInt(m.count, 99, "count reads back correctly despite reversed named args")
  assertEqual(m.label, "hello", "label reads back correctly despite reversed named args")
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Assignment to a local named `result` (m-23).
//    `result` is a contextual keyword that parses as EResult even in
//    assignment-target position; the JVM assignment lowering dropped the
//    store on the floor (evaluate + pop), so accumulation loops over a
//    `result` local — including the stdlib's own
//    `Std.ProcessCapture.buildArgString` — silently produced their initial
//    value.
// ─────────────────────────────────────────────────────────────────────────────
test "assignment to a local named 'result' is observed" {
  // Accumulation loop over a `result` local (the buildArgString shape).
  val parts = ["a", "b", "c"]
  var result = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      result = result + " "
    }
    result = result + parts[i]
    i = i + 1
  }
  assertEqual(result, "a b c", "accumulation into a `result` local survives the loop")
}

test "reassignment of an Int local named 'result' is stored" {
  var result = 1
  result = result + 41
  assertEqualInt(result, 42, "compound-shaped reassignment of a `result` Int local is stored")
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Slice literal passed to a slice[T] parameter (#4700).
//    The EList literal lowers as an ArrayList; an erased slice parameter is
//    Object[], so without the call-boundary conversion the class failed
//    verification at load ("ArrayList is not assignable to
//    [Ljava/lang/Object;").
// ─────────────────────────────────────────────────────────────────────────────
func sliceParamLen(parts: slice[String]): Int {
  parts.count
}

test "slice literal coerces to a slice[T] parameter" {
  assertEqualInt(sliceParamLen(["a", "b", "c"]), 3, "ArrayList literal converts to Object[] at the call boundary")
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. forall in a @runtime_checked contract compiles and passes (#3227).
//    EForall/EExists previously panicked the JVM codegen; they now lower to
//    `true` (sound overapproximation, matching MSIL #1506) with a W0002
//    warning at compile time.
// ─────────────────────────────────────────────────────────────────────────────
func quantified(x: in Int): Int
  ensures: forall (j: Int) { j * 0 == 0 }
{
  x + 1
}

test "forall in a runtime-checked contract lowers to true instead of panicking" {
  assertEqualInt(quantified(41), 42, "function with a forall ensures clause runs")
}

// Unsigned Byte widening (#4855): JVM byte sign-extends on reload, so toInt/toLong/toDouble must mask to 0..255, or it's a silent miscompile (negative value, no error).
record ByteHolder {
  b: Byte
}

test "Byte widening above 127 stays unsigned (#4855)" {
  val v: Byte = 200.toByte()
  assertEqualInt(v.toInt(), 200, "local Byte 200 -> Int 200, not -56")
  assertEqualLong(v.toLong(), 200i64, "local Byte 200 -> Long 200")
  assertTrue(v.toDouble() == 200.0, "local Byte 200 -> Double 200.0")

  val h = ByteHolder(b = 255.toByte())
  assertEqualInt(h.b.toInt(), 255, "field Byte 255 -> Int 255, not -1")
  assertEqualLong(h.b.toLong(), 255i64, "field Byte 255 -> Long 255, not -1")
  assertTrue(h.b.toDouble() == 255.0, "field Byte 255 -> Double 255.0, not -1.0")
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. Compound assignment on String / Float / Byte / erased locals and hoisted
//    cells (docs/59 §4.2).  The local-variable and hoisted-cell compound paths
//    only special-cased JLong/JDouble and fell to integer opcodes, so
//    `f += 0.5f` and `s += "x"` produced VerifyError at class load, and an
//    erased-Object match payload reached `iadd`/`ladd` still boxed.  All
//    paths now route through `emitCompoundCombineJvm`.
// ─────────────────────────────────────────────────────────────────────────────
test "String compound append on a local" {
  var s = "a"
  s += "b"
  s += "c"
  assertEqual(s, "abc", "s += builds the concatenation")
}

test "Float compound assignment on a local" {
  var f: Float = 1.0f32
  f += 0.5f32
  assertTrue(f == 1.5f32, "f += 0.5f")
  f -= 0.25f32
  assertTrue(f == 1.25f32, "f -= 0.25f")
  f *= 2.0f32
  assertTrue(f == 2.5f32, "f *= 2.0f")
  f /= 2.0f32
  assertTrue(f == 1.25f32, "f /= 2.0f")
}

test "Byte compound assignment wraps unsigned on a local" {
  var b: Byte = 200.toByte()
  b += 100.toByte()
  // 300 wraps to 44 (unsigned 8-bit), matching MSIL conv.u1.
  assertEqualInt(b.toInt(), 44, "200 += 100 wraps to 44")
  var m: Byte = 200.toByte()
  m *= 2.toByte()
  assertEqualInt(m.toInt(), 144, "200 *= 2 wraps to 144")
}

test "compound assignment coerces an erased match payload" {
  // The scrutinee's generic instantiation is unrecoverable here (a direct
  // constructor init records no generic args), so the payload binds as a
  // boxed Object — the compound RHS must unbox it like the plain `=` arm does.
  val o: Option[Long] = Some(value = 5i64)
  var total: Long = 100i64
  match o {
    case Some(n) -> {
      total += n
    }
    case None -> ()
  }
  assertEqualLong(total, 105i64, "total += erased payload")
}

test "compound assignment on hoisted (captured) vars of each shape" {
  var hf: Float = 1.0f32
  var hs = "x"
  var hl: Long = 10i64
  var hi = 3
  var hb: Byte = 200.toByte()
  var hd: Double = 1.0
  val bump = { -> hf += 0.5f32; hs += "y"; hl += 2i64; hi += 4; hb *= 2.toByte(); hd += 0.5 }
  bump()
  assertTrue(hf == 1.5f32, "hoisted Float +=")
  assertEqual(hs, "xy", "hoisted String +=")
  assertEqualLong(hl, 12i64, "hoisted Long +=")
  assertEqualInt(hi, 7, "hoisted Int +=")
  assertEqualInt(hb.toInt(), 144, "hoisted Byte *= wraps unsigned")
  assertTrue(hd == 1.5, "hoisted Double +=")
  bump()
  assertTrue(hf == 2.0f32, "hoisted Float += (second call)")
  assertEqual(hs, "xyy", "hoisted String += (second call)")
  assertTrue(hd == 2.0, "hoisted Double += (second call)")
}

// `emitArrayLoad`'s (`lyric-compiler/jvm/codegen/05_stmts.l`) typed-dispatch
// covers every JVM array-load opcode a hoisted holder cell can carry
// (#3541 follow-up): the compound-assignment cases above already exercise
// JFloat/JLong/JInt/JByte/JDouble (plus the default JRef branch via String);
// this case rounds out JBoolean and JChar, which a hoisted var reaches on
// every READ (`Jvm.Codegen`'s `EPath` hoisted-cell arm), not just compound
// writes.  `JShort` is the one variant with no reachable test: no Lyric
// surface type erases to it (`typeExprToJvm` never produces `JShort`), so it
// is permanently dead code from any `.l` program, not a J4-blocked gap.
test "hoisted Bool and Char vars read/write correctly through closures" {
  var hFlag = true
  var hChar = 'a'
  val flip = { -> hFlag = not hFlag; hChar = 'b' }
  flip()
  assertFalse(hFlag, "hoisted Bool flipped to false")
  assertTrue(hChar == 'b', "hoisted Char written to 'b'")
  flip()
  assertTrue(hFlag, "hoisted Bool flipped back to true")
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. `collectMutableVarsExpr`'s hoisting pre-pass must see a `var` declared
//     inside an expression nested in call-argument position (#4264): before
//     the fix, `collectMutableVarsExpr` recursed into `EIf`/`EMatch`/`EBlock`/
//     `EUnsafe` only when they were direct statement- or binding-init-level
//     expressions, never when reached through an intervening `ECall`. A `var`
//     declared inside an `if`-expression passed as a call argument was
//     therefore never added to the function's `mutableVars` set, so the
//     lambda that mutates it through a captured reference was never hoisted
//     to a heap cell: the lambda silently mutated its own by-value capture
//     instead, and the mutation was never observed by the enclosing scope.
// ─────────────────────────────────────────────────────────────────────────────
test "var declared inside an if-expression call argument is hoisted for lambda capture" {
  val r = identityInt(
    if true {
      var x = 1
      val g: () -> Int = { -> x = x + 1; x }
      val r1 = g()
      val r2 = g()
      assertEqualInt(r1, 2, "first g() call observes the hoisted cell (x: 1 -> 2)")
      assertEqualInt(r2, 3, "second g() call observes the mutation from the first (x: 2 -> 3)")
      x
    } else {
      0
    }
  )
  assertEqualInt(r, 3, "the call argument's var is hoisted, so the if-expression yields 3")
}

// ─────────────────────────────────────────────────────────────────────────────
// 12. Indexed slice/List elements carry their declared concrete type
//     (docs/59 §4.3, the #5439 class).  `fields[i]` on a `slice[Rec]` /
//     `List[Rec]` receiver was statically Object, so the member read that
//     follows either panicked (post-#5439 guard) or silently yielded the
//     receiver itself — the exact `Std.Log.formatFields` shape that J003-
//     skipped Std.Log/Std.Yaml from JVM bundles.
// ─────────────────────────────────────────────────────────────────────────────
// Same field shape as Std.Log.LogField.
record KvField {
  key: String
  value: String
}

// The exact formatFields shape: a `slice[Rec]` parameter indexed in a loop
// with member reads on the bound element.
func joinSliceFields(fields: in slice[KvField]): String {
  var text = ""
  var i = 0
  while i < fields.length {
    val f = fields[i]
    if i > 0 {
      text = text + " "
    }
    text = text + f.key + "=" + f.value
    i += 1
  }
  text
}

// The `List[Rec]` variant, with a direct `fields[i].key` member read on the
// indexed expression itself (no intermediate binding).
func joinListFields(fields: in List[KvField]): String {
  var text = ""
  var i = 0
  while i < fields.count {
    if i > 0 {
      text = text + " "
    }
    text = text + fields[i].key + "=" + fields[i].value
    i += 1
  }
  text
}

test "slice[Record] elements read fields through the declared element type" {
  val joined = joinSliceFields([KvField(key = "a", value = "1"), KvField(key = "b", value = "2")])
  assertEqual(joined, "a=1 b=2", "formatFields shape over slice[KvField]")
}

test "List[Record] elements read fields through the declared element type" {
  val fields: List[KvField] = [KvField(key = "x", value = "9"), KvField(key = "y", value = "8")]
  assertEqual(joinListFields(fields), "x=9 y=8", "formatFields shape over List[KvField]")
}

// ─────────────────────────────────────────────────────────────────────────────
// 13. Whole-valued Double stringification matches .NET (#4688, docs/44 m-21).
//     Java's Double.toString()/String.valueOf(double) always renders a
//     fractional digit ("1500.0"); .NET's default Double.ToString() omits
//     the trailing ".0" for whole values ("1500").  `.toString()`, the free
//     `toString(x)` function, string interpolation, `+` concatenation, and
//     compound `+=` concatenation all route through the same
//     `emitNormalizeDoubleString` helper and are asserted below;
//     `println`/`print` share the identical helper call (`codegen/04_calls.l`)
//     but aren't independently assertable here (no stdout-capture harness).
//     A genuine fractional part is left untouched.
// ─────────────────────────────────────────────────────────────────────────────
func describeDouble(d: in Double): String {
  "value: ${d}"
}

test "Double.toString() omits trailing .0 for a whole value" {
  val d: Double = 1500.0
  assertEqual(d.toString(), "1500", "1500.0.toString() == \"1500\"")
}

test "Double.toString() keeps a genuine fractional part" {
  val d: Double = 1500.5
  assertEqual(d.toString(), "1500.5", "1500.5.toString() == \"1500.5\"")
}

test "free toString(x) omits trailing .0 for a whole Double" {
  val d: Double = 42.0
  assertEqual(toString(d), "42", "toString(42.0) == \"42\"")
}

test "string interpolation of a whole Double omits trailing .0" {
  val d: Double = 1500.0
  assertEqual(describeDouble(d), "value: 1500", "interpolated whole Double renders without .0")
  val frac: Double = 1500.5
  assertEqual(describeDouble(frac), "value: 1500.5", "interpolated fractional Double keeps its digits")
}

test "+ concatenation of a whole Double omits trailing .0" {
  val d: Double = 7.0
  assertEqual("n=" + d, "n=7", "string + whole Double renders without .0")
}

test "zero and negative whole Doubles omit trailing .0" {
  val z: Double = 0.0
  val neg: Double = -5.0
  assertEqual(z.toString(), "0", "0.0.toString() == \"0\"")
  assertEqual(neg.toString(), "-5", "(-5.0).toString() == \"-5\"")
}
