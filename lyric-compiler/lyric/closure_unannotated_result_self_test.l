//! closure_unannotated_result_self_test.l — calling a function value bound
//! to an unannotated local yields the closure's real result (#7711).
//!
//! On `--target dotnet` a closure is a uniform boxed `Func<object, ...>`, so
//! a call through it returns a boxed `object` the call site must unbox to the
//! closure's result type.  Codegen learned that type from the binding's
//! annotation or from a syntactic guess at the lambda body, which fails for a
//! body that reads a captured local (`{ -> base + 1 }`): the call then
//! returned the box's object reference as an `Int`.  The type checker now
//! records each unannotated function-valued local's checked type and
//! `Lyric.Mono.desugarCheckedFile` writes it onto the binding.
//!
//! A callee bound where no annotation can go failed the same way (#7716): a
//! `for` loop variable, a `match` pattern binding, a destructured tuple
//! element, a list element (`fs[0]()`), and a record field read off a
//! receiver codegen sees only as `object` (`hs[0].get()`).  The type checker
//! also records the callee type of every call through a function value
//! (`SymbolTable.funcValueCallSites`), and the desugar calls it through a
//! local annotated with that type, so the result is unboxed however the
//! callee was bound.  The JVM rejected the tuple and list-element forms at
//! compile time (J008) before the same change.
//!
//! Runs on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/closure_unannotated_result_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/closure_unannotated_result_self_test.l
@test_module
package ClosureUnannotatedResultTest

import Std.Core
import Std.Testing

record Pt {
  x: Int
  y: Int
}

func tailCall(base: in Int): Int {
  val inner = { -> base + 1 }
  inner()
}

func afterReturn(base: in Int): Int {
  val inner = { -> base + 1 }
  return inner()
}

func boundResult(base: in Int): Int {
  val inner = { -> base + 1 }
  val r = inner()
  r + 0
}

func nestedClosure(base: in Int): Int {
  val h = { -> val inner = { -> base + 1 }; inner() }
  h()
}

func nestedCapturedTwice(base: in Int, extra: in Int): Int {
  val scaled = base * 3
  val h = { -> val inner = { -> scaled + extra + 1 }; inner() }
  h()
}

func outerClosureCalledInside(base: in Int): Int {
  val inner = { -> base + 1 }
  val h = { -> inner() * 2 }
  h()
}

func longResult(base: in Long): Long {
  val inner = { -> base * 2 }
  inner()
}

func boolResult(base: in Int): Bool {
  val inner = { -> base > 3 }
  inner()
}

func doubleResult(base: in Double): Double {
  val inner = { -> base + 0.5 }
  inner()
}

func stringResult(base: in Int): String {
  val inner = { -> "v" + toString(base) }
  inner()
}

func recordResult(base: in Int): Int {
  val inner = { -> Pt(x = base, y = base + 1) }
  val p = inner()
  p.x + p.y
}

func optionResult(base: in Int): Int {
  val inner = { -> Some(base + 1) }
  match inner() {
    case Some(v) -> v
    case None -> 0
  }
}

func unitResult(base: in Int): Int {
  var acc = 0
  val bump = { -> acc = acc + base }
  bump()
  bump()
  acc
}

func withArgument(base: in Int): Int {
  val add = { x: Int -> x + base }
  add(3) + add(4)
}

func varBinding(base: in Int): Int {
  var f = { -> base + 1 }
  val first = f()
  f = { -> base + 10 }
  first + f()
}

func applyTwice(f: in () -> Int): Int {
  f() + f()
}

func passedAsParameter(base: in Int): Int {
  val inner = { -> base + 1 }
  applyTwice(inner)
}

func makeAdder(base: in Int): (Int) -> Int {
  { x: Int -> x + base }
}

func returnedFromFunction(base: in Int): Int {
  val add = makeAdder(base)
  val r = add(5)
  r + 0
}

func twice(x: in Int): Int {
  x * 2
}

func bareFunctionValue(base: in Int): Int {
  val f = twice
  f(base) + 0
}

func conditionalClosure(flag: in Bool, base: in Int): Int {
  val f = if flag { { -> base + 1 } } else { { -> base - 1 } }
  f()
}

record IntThunk {
  get: () -> Int
}

record LongThunk {
  get: () -> Long
}

record DoubleThunk {
  get: () -> Double
}

record OptThunk {
  get: () -> Option[Int]
}

func optOr0(o: in Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None -> 0
  }
}

// ── Callees with no annotation slot (#7716) ──────────────────────────────
func forLoopInt(base: in Int): Int {
  val fs = [{ -> base + 1 }, { -> base + 2 }]
  var acc = 0
  for f in fs {
    acc = acc + f()
  }
  acc
}

func forLoopLong(base: in Long): Long {
  val fs = [{ -> base * 2 }, { -> base * 3 }]
  var acc = 0i64
  for f in fs {
    acc = acc + f()
  }
  acc
}

func forLoopDouble(base: in Double): Double {
  val fs = [{ -> base + 0.25 }, { -> base + 0.5 }]
  var acc = 0.0
  for f in fs {
    acc = acc + f()
  }
  acc
}

func forLoopOption(base: in Int): Int {
  val fs = [{ -> Some(base + 1) }, { -> Some(base * 2) }]
  var acc = 0
  for f in fs {
    acc = acc + optOr0(f())
  }
  acc
}

func forLoopWithArgument(base: in Int): Int {
  val fs = [{ x: Int -> x + base }, { x: Int -> x * base }]
  var acc = 0
  for f in fs {
    acc = acc + f(3)
  }
  acc
}

func matchBoundInt(base: in Int): Int {
  match Some({ -> base + 3 }) {
    case Some(f) -> f()
    case None -> 0
  }
}

func matchBoundLong(base: in Long): Long {
  match Some({ -> base * 4 }) {
    case Some(f) -> f()
    case None -> 0i64
  }
}

func matchBoundDouble(base: in Double): Double {
  match Some({ -> base + 0.75 }) {
    case Some(f) -> f()
    case None -> 0.0
  }
}

func matchBoundOption(base: in Int): Int {
  match Some({ -> Some(base + 5) }) {
    case Some(f) -> optOr0(f())
    case None -> 0
  }
}

func tupleInt(base: in Int): Int {
  val (f, g) = ({ -> base + 1 }, { -> base + 2 })
  f() + g()
}

func tupleLong(base: in Long): Long {
  val (f, g) = ({ -> base * 2 }, { -> base * 3 })
  f() + g()
}

func tupleDouble(base: in Double): Double {
  val (f, g) = ({ -> base + 0.25 }, { -> base + 0.5 })
  f() + g()
}

func tupleOption(base: in Int): Int {
  val (f, g) = ({ -> Some(base + 1) }, { -> Some(base + 2) })
  optOr0(f()) + optOr0(g())
}

func fieldInt(base: in Int): Int {
  val h = IntThunk(get = { -> base + 4 })
  h.get() + 0
}

func fieldLong(base: in Long): Long {
  val h = LongThunk(get = { -> base * 5 })
  h.get() + 0i64
}

func fieldDouble(base: in Double): Double {
  val h = DoubleThunk(get = { -> base + 1.25 })
  h.get() + 0.0
}

func fieldOption(base: in Int): Int {
  val h = OptThunk(get = { -> Some(base + 6) })
  optOr0(h.get())
}

func listElementFieldInt(base: in Int): Int {
  val hs = [IntThunk(get = { -> base + 1 }), IntThunk(get = { -> base + 2 })]
  hs[0].get() + hs[1].get()
}

func indexInt(base: in Int): Int {
  val fs = [{ -> base + 1 }, { -> base + 2 }]
  fs[0]() + fs[1]()
}

func indexLong(base: in Long): Long {
  val fs = [{ -> base * 2 }, { -> base * 3 }]
  fs[0]() + fs[1]()
}

func indexDouble(base: in Double): Double {
  val fs = [{ -> base + 0.25 }, { -> base + 0.5 }]
  fs[0]() + fs[1]()
}

func indexOption(base: in Int): Int {
  val fs = [{ -> Some(base + 1) }, { -> Some(base + 2) }]
  optOr0(fs[0]()) + optOr0(fs[1]())
}

func loopInsideClosure(base: in Int): Int {
  val fs = [{ -> base + 1 }, { -> base + 2 }]
  val total = { -> var acc = 0; for f in fs { acc = acc + f() }; acc }
  total()
}

func parseDigit(s: in String): Result[Int, String] {
  if s == "7" {
    Ok(value = 7)
  } else {
    Err(error = "not 7: " + s)
  }
}

func propagatedResult(base: in Int): Result[Int, String] {
  val fs = [{ s: String -> parseDigit(s) }]
  var acc = base
  for f in fs {
    acc = acc + f("7")?
  }
  Ok(value = acc)
}

func propagatedArgument(base: in Int): Result[Int, String] {
  val fs = [{ x: Int -> x + base }]
  var acc = 0
  for f in fs {
    acc = acc + f(parseDigit("7")?)
  }
  Ok(value = acc)
}

async func plusOne(x: in Int): Int {
  x + 1
}

async func awaitedArgument(base: in Int): Int {
  val fs = [{ x: Int -> x * base }]
  var acc = 0
  for f in fs {
    acc = acc + f(await plusOne(2))
  }
  acc
}

func nestedValueCalls(base: in Int): Int {
  val fs = [{ x: Int -> x + base }]
  var acc = 0
  for f in fs {
    acc = acc + f(f(f(1)))
  }
  acc
}

test "tail-position call" {
  assertEqualInt(tailCall(7), 8, "tail")
}

test "call after return" {
  assertEqualInt(afterReturn(7), 8, "return")
}

test "call bound to an unannotated val" {
  assertEqualInt(boundResult(7), 8, "bound")
}

test "nested closure" {
  assertEqualInt(nestedClosure(7), 8, "nested")
}

test "nested closure reading two captures" {
  assertEqualInt(nestedCapturedTwice(7, 5), 27, "nested twice")
}

test "captured closure called inside another" {
  assertEqualInt(outerClosureCalledInside(7), 16, "captured closure")
}

test "Long result" {
  assertEqualLong(longResult(21i64), 42i64, "long")
}

test "Bool result" {
  assertTrue(boolResult(7), "bool true")
  assertFalse(boolResult(2), "bool false")
}

test "Double result" {
  assertTrue(doubleResult(1.0) == 1.5, "double")
}

test "String result" {
  assertEqual(stringResult(4), "v4", "string")
}

test "record result" {
  assertEqualInt(recordResult(4), 9, "record")
}

test "Option[Int] result" {
  assertEqualInt(optionResult(4), 5, "option")
}

test "Unit result" {
  assertEqualInt(unitResult(4), 8, "unit")
}

test "closure with an argument" {
  assertEqualInt(withArgument(10), 27, "argument")
}

test "var-bound closure reassigned" {
  assertEqualInt(varBinding(1), 13, "var")
}

test "closure passed as a parameter" {
  assertEqualInt(passedAsParameter(4), 10, "parameter")
}

test "closure returned from a function" {
  assertEqualInt(returnedFromFunction(2), 7, "returned")
}

test "bare function value" {
  assertEqualInt(bareFunctionValue(6), 12, "bare")
}

test "closure chosen by if" {
  assertEqualInt(conditionalClosure(true, 5), 6, "if then")
  assertEqualInt(conditionalClosure(false, 5), 4, "if else")
}

test "for-loop variable" {
  assertEqualInt(forLoopInt(1), 5, "for Int")
  assertEqualLong(forLoopLong(2i64), 10i64, "for Long")
  assertTrue(forLoopDouble(1.0) == 2.75, "for Double")
  assertEqualInt(forLoopOption(4), 13, "for Option[Int]")
  assertEqualInt(forLoopWithArgument(2), 11, "for with argument")
}

test "match pattern binding" {
  assertEqualInt(matchBoundInt(1), 4, "match Int")
  assertEqualLong(matchBoundLong(3i64), 12i64, "match Long")
  assertTrue(matchBoundDouble(1.0) == 1.75, "match Double")
  assertEqualInt(matchBoundOption(1), 6, "match Option[Int]")
}

test "tuple destructuring" {
  assertEqualInt(tupleInt(1), 5, "tuple Int")
  assertEqualLong(tupleLong(2i64), 10i64, "tuple Long")
  assertTrue(tupleDouble(1.0) == 2.75, "tuple Double")
  assertEqualInt(tupleOption(1), 5, "tuple Option[Int]")
}

test "record field holding a closure" {
  assertEqualInt(fieldInt(1), 5, "field Int")
  assertEqualLong(fieldLong(2i64), 10i64, "field Long")
  assertTrue(fieldDouble(1.0) == 2.25, "field Double")
  assertEqualInt(fieldOption(1), 7, "field Option[Int]")
  assertEqualInt(listElementFieldInt(1), 5, "list element field")
}

test "list element call" {
  assertEqualInt(indexInt(1), 5, "index Int")
  assertEqualLong(indexLong(2i64), 10i64, "index Long")
  assertTrue(indexDouble(1.0) == 2.75, "index Double")
  assertEqualInt(indexOption(1), 5, "index Option[Int]")
}

test "for-loop variable inside a closure" {
  assertEqualInt(loopInsideClosure(1), 5, "loop in closure")
}

test "`?` in and around a loop-bound closure call" {
  match propagatedResult(1) {
    case Ok(v) -> assertEqualInt(v, 8, "result propagated")
    case Err(e) -> assertTrue(false, e)
  }
  match propagatedArgument(1) {
    case Ok(v) -> assertEqualInt(v, 8, "argument propagated")
    case Err(e) -> assertTrue(false, e)
  }
}

test "awaited argument to a loop-bound closure" {
  assertEqualInt(await awaitedArgument(5), 15, "await")
}

test "nested loop-bound closure calls" {
  assertEqualInt(nestedValueCalls(2), 7, "nested")
}
