// outparam_self_test.l — executable regression test for self-hosted
// `out` / `inout` parameter passing (#1761).
//
// Why this lives here and not in `lyric-stdlib/tests/*_tests.l`:
// those `_tests.l` files are compiled and run by the **F# stage-0**
// emitter, which already lowers `out`/`inout` params to managed byref
// correctly — so they cannot regression-test the *self-hosted* path.
// Before #1761 the self-hosted MSIL backend emitted every parameter by
// value, so a callee's write to an `out`/`inout` param never reached the
// caller (`out String` came back empty; `inout Int` mutations were lost).
// This file is run by the native `lyric test` (issue #1611):
//
//   lyric test lyric-compiler/lyric/outparam_self_test.l
//
// `lyric test` synthesises a runnable program from the `test` blocks and
// compiles it IN-PROCESS through the self-hosted `Msil.Bridge`, then runs
// it and asserts every embedded assertion held.  Imports only `Std.*`, so
// no `LYRIC_LOAD_COMPILER=1` is needed.
//
// MSIL only for now; JVM-target parity is tracked in #1763 (the JVM backend has
// no managed byref and needs a holder-array lowering).

@test_module
package Lyric.OutParamSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// out — write-only parameter; the callee's write must reach the caller.
// ─────────────────────────────────────────────────────────────────────────────

func setString(src: in String, dst: out String): Bool {
  dst = src
  true
}

test "out String write propagates to the caller (the #1079 / #1761 shape)" {
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

// Two out parameters written in one call.
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

// ─────────────────────────────────────────────────────────────────────────────
// inout — read-modify-write; the callee both reads the incoming value and
// writes an updated one back (the YAML / generator-sdk `pos: inout Int` shape).
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
// exercises passing an inout param as an inout argument to a nested call.
func bumpTwice(pos: inout Int): Unit {
  advance(1, pos)
  advance(1, pos)
}

test "inout param forwarded as an inout argument to a nested call" {
  var p: Int = 0
  bumpTwice(p)
  assertEqualInt(p, 2, "nested inout forwarding must compose")
}
