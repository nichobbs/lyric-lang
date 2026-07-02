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
  count: Int
  label: String
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
func accumulateIntoResult(parts: slice[String]): String {
  var result = ""
  var i = 0
  while i < parts.count {
    if i > 0 {
      result = result + " "
    }
    result = result + parts[i]
    i = i + 1
  }
  result
}

test "assignment to a local named 'result' is observed" {
  assertEqual(accumulateIntoResult(["a", "b", "c"]), "a b c", "accumulation into a `result` local survives the loop")
  var result = 1
  result = result + 41
  assertEqualInt(result, 42, "compound-shaped reassignment of a `result` Int local is stored")
}
