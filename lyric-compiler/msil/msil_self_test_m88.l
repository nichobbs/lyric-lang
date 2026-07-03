//! Test constructor shorthand for extern types (.new syntax).
//! Tests docs/48 implementation: enable `.new(args)` calls on external types,
//! eliminating `@externTarget` wrapper functions and aligning MSIL with JVM.

@test_module
package Lyric.ConstructorShorthand

import Std.Core
import Std.Collections
import Std.Testing

extern type SBld = "System.Text.StringBuilder"

@externTarget("System.Text.StringBuilder.get_Length")
@externInstance
func sbLength(sb: in SBld): Int = ()

@externTarget("System.Text.StringBuilder.get_Capacity")
@externInstance
func sbCapacity(sb: in SBld): Int = ()

test "StringBuilder.new()" {
  val sb = SBld.new()
  assertEqualInt(sbLength(sb), 0, "newly constructed StringBuilder is empty")
}

test "StringBuilder.new(capacity)" {
  val capacity = 32
  val sb = SBld.new(capacity)
  assertTrue(sbCapacity(sb) >= capacity, "capacity constructor respects size")
}

test "constructor overload resolution" {
  val sb0 = SBld.new()
  val sb1 = SBld.new(64)

  assertEqualInt(sbLength(sb0), 0, "zero-arg constructor produces empty StringBuilder")
  assertTrue(sbCapacity(sb1) >= 64, "capacity constructor respects requested size")
}

test "StringBuilder.new(String)" {
  val initialContent = "hello"
  val sb = SBld.new(initialContent)
  assertEqualInt(sbLength(sb), 5, "string-argument constructor initializes length correctly")
}

// Regression coverage for the cross-package generic TypeRef arity-suffix
// resolution fix (#4284, #4289, #4294, #4297, #4300; tracked test gaps
// #4287, #4290, #4295, #4299, #4302).  `Result`/`Option` are defined in
// `Std.Core` — a different assembly from this test module — so returning
// and matching them here forces `bufMsilTypeWithCtx`'s `MGenericInstByName`
// path (lowering.l) to resolve `Std.Core.Result`2`/`Std.Core.Option`1`
// through the arity-suffixed-first, plain-FQN-fallback TypeRef lookup
// rather than degrading to `System.Object` (W0005).
func crossPkgGenericResult(x: Int): Result[Int, String] {
  if x >= 0 {
    Ok(value = x)
  } else {
    Err(error = "negative")
  }
}

func crossPkgGenericOption(x: Int): Option[Int] {
  if x >= 0 {
    Some(value = x)
  } else {
    None
  }
}

test "cross-package Result[Int,String] resolves through Std.Core TypeRef" {
  match crossPkgGenericResult(5) {
    case Ok(v) -> assertEqualInt(v, 5, "Ok(5).value")
    case Err(_) -> assertTrue(false, "expected Ok for non-negative input")
  }
  match crossPkgGenericResult(-1) {
    case Ok(_) -> assertTrue(false, "expected Err for negative input")
    case Err(e) -> assertEqual(e, "negative", "Err(-1).error")
  }
}

test "cross-package Option[Int] resolves through Std.Core TypeRef" {
  match crossPkgGenericOption(7) {
    case Some(v) -> assertEqualInt(v, 7, "Some(7).value")
    case None -> assertTrue(false, "expected Some for non-negative input")
  }
  match crossPkgGenericOption(-1) {
    case Some(_) -> assertTrue(false, "expected None for negative input")
    case None -> assertTrue(true, "None for negative input")
  }
}

// Regression coverage for the `trimStart`/`trimEnd` MSIL intrinsics
// (`lowerMethodCallMsil` in codegen.l), added without a dedicated test (#4045).
test "String.trimStart() removes only leading whitespace" {
  assertEqual("  hello  ".trimStart(), "hello  ", "trimStart trims leading only")
  assertEqual("hello".trimStart(), "hello", "trimStart is a no-op with no leading whitespace")
}

test "String.trimEnd() removes only trailing whitespace" {
  assertEqual("  hello  ".trimEnd(), "  hello", "trimEnd trims trailing only")
  assertEqual("hello".trimEnd(), "hello", "trimEnd is a no-op with no trailing whitespace")
}

// Regression coverage for `break` inside a `for` loop over an
// `MExternEnumerable` (the non-generic `IEnumerable`/`IEnumerator` protocol
// used by `mapKeys`/`mapValues`, #3511).  PR #4754 wrapped this loop shape in
// a try/finally so the `IEnumerator` is disposed on exhaustion or early
// `break` (#4594).  `break` exits the try/finally via `emitLoopJumpMsil`,
// which must emit `leave` (not a plain `br`) to cross the protected-region
// boundary — a `br` straight out of a try/finally is invalid MSIL that
// throws at assembly load time (#4769).  This test does not (and cannot,
// from within the language) directly observe which opcode was emitted; it
// exercises the path end-to-end — if `emitLoopJumpMsil` emitted `br` here,
// the compiled assembly would fail IL verification before this test body
// ever ran, rather than merely producing the wrong count.
test "break inside an extern-enumerable for-loop (mapKeys) exits early" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  m.add("c", 3)
  var count = 0
  for _k in mapKeys(m) {
    count = count + 1
    if count == 2 {
      break
    }
  }
  assertEqualInt(count, 2, "loop stops after the second key regardless of enumeration order")
}

