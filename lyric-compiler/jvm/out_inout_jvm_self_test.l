//! out_inout_jvm_self_test.l — executable regression test for the self-hosted
//! JVM backend's `out` / `inout` parameter passing (#1763, follow-up to #1761).
//!
//! The JVM has no managed byref (MSIL's `T&`), so an `out`/`inout` parameter of
//! element type T is lowered to a single-element *holder array* (`[I`, `[J`,
//! `[Ljava/lang/String;`, …): the caller allocates the array pre-filled with the
//! local's current value, passes it, and copies element 0 back into the local
//! after the call; the callee unwraps the holder into a value slot on entry and
//! writes every update through to `holder[0]`.  See `lowerStaticCallWithHolders`
//! / `setupStaticParamSlotsAndHolders` in `lyric-compiler/jvm/codegen/`.
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/out_inout_jvm_self_test.l
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it IN-PROCESS through the self-hosted `Jvm.Bridge`
//! (`compileToJarBundled`), then runs it under `java` and asserts every embedded
//! assertion held.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is
//! needed.
//!
//! Scope: this guards the **free-function** holder lowering (the #1761 motivating
//! shape — `Auth.Kernel.Net.tryExtractClaim(value: out String)` is a free
//! function).  `out`/`inout` parameters on instance/interface methods are now
//! also supported on JVM (see `out_inout_instance_jvm_self_test.l` for the
//! instance-method regression tests, #1763).  The MSIL companion
//! `lyric-compiler/lyric/outparam_self_test.l` covers instance-method cases on
//! `--target dotnet`.
@test_module
package Lyric.OutInoutJvmSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// out — write-only parameter; the callee's write must reach the caller.
// ─────────────────────────────────────────────────────────────────────────────
func setString(src: in String, dst: out String): Bool {
  dst = src
  true
}

test "out String write propagates to the caller (the #1761 shape)" {
  var v: String = ""
  val ok = setString("alice", v)
  assertTrue(ok, "callee returns true")
  assertEqual(v, "alice", "out String write must be observed by the caller")
}

func setInt(n: in Int, dst: out Int): Unit {
  dst = n * 2
}

test "out Int write propagates to the caller" {
  var x: Int = 0
  setInt(21, x)
  assertEqualInt(x, 42, "out Int write must be observed by the caller")
}

// Two out parameters written in one call: pins that the holder arrays for
// distinct positions stay independent and both are copied back.
func divmod(a: in Int, b: in Int, q: out Int, r: out Int): Unit {
  q = a / b
  r = a % b
}

test "multiple out params are all written back" {
  var q: Int = 0
  var r: Int = 0
  divmod(17, 5, q, r)
  assertEqualInt(q, 3, "quotient out param")
  assertEqualInt(r, 2, "remainder out param")
}

// A wide element type (Long) exercises the two-slot holder value-local and the
// `[J` / lastore/laload path.
func setLong(n: in Long, dst: out Long): Unit {
  dst = n + 1000i64
}

test "out Long (two-word element) writes back" {
  var y: Long = 0i64
  setLong(42i64, y)
  assertTrue(y == 1042i64, "out Long write must be observed by the caller")
}

// ─────────────────────────────────────────────────────────────────────────────
// inout — read-modify-write; the callee both reads the incoming value and
// writes an updated one back.
// ─────────────────────────────────────────────────────────────────────────────
func advance(by: in Int, pos: inout Int): Unit {
  pos = pos + by
}

test "inout Int read-modify-write propagates" {
  var pos: Int = 10
  advance(5, pos)
  assertEqualInt(pos, 15, "inout must read 10 then write 15")
  advance(100, pos)
  assertEqualInt(pos, 115, "inout accumulates across calls")
}

func appendBang(s: inout String): Unit {
  s = s + "!"
}

test "inout String read-modify-write propagates" {
  var s: String = "hi"
  appendBang(s)
  appendBang(s)
  assertEqual(s, "hi!!", "inout String must read then write back twice")
}

// inout threaded through a helper that itself takes the parameter inout:
// exercises passing an inout param as an inout argument to a nested call
// (forwarding), and that the forwarding readback keeps the outer holder in sync.
func bumpTwice(pos: inout Int): Unit {
  advance(1, pos)
  advance(1, pos)
}

test "inout param forwarded as an inout argument to a nested call" {
  var p: Int = 0
  bumpTwice(p)
  assertEqualInt(p, 2, "nested inout forwarding must compose")
}

// Mixed in/out/inout in one signature: position 0 is by-value, position 1 is
// out, position 2 is inout — verifies the mode index mapping across positions.
func mix(a: in Int, b: out Int, c: inout Int): Unit {
  b = a * 2
  c = c + a
}

test "mixed-mode (in, out, inout) all positions index correctly" {
  var b: Int = 0
  var c: Int = 10
  mix(3, b, c)
  assertEqualInt(b, 6, "out param (pos 1): 3*2 = 6")
  assertEqualInt(c, 13, "inout param (pos 2): 10+3 = 13")
}
