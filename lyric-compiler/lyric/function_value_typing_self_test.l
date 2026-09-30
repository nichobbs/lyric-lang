//! function_value_typing_self_test.l — dual-target runtime regression test for
//! the typing of lambdas (#7865).
//!
//! A generic call whose only evidence for a type parameter is a lambda
//! argument specialises at the type the type checker resolved for the call,
//! even where the monomorphizer cannot type the lambda body itself: a body
//! reading an unannotated module `val`, or ending in an `if`, a `match` or a
//! block.  Such a call used to fail with `M0002` on both targets.
//!
//! A lambda checked where a function type is expected takes that type's return
//! type as its own, as a function's body takes its declared return type: the
//! body's value and each `return` in it widen along the lossless chains
//! (docs/01 §4.1), so `{ -> 5 }` is a `() -> Long` where one is expected
//! (T0060 before), and the widened value is built at the wider type on both
//! targets.  A `return` nested in a branch of a lambda body is checked against
//! the lambda's return type, not the enclosing function's.  An unannotated
//! parameter has the expected parameter type on both targets; the JVM used to
//! type it `Object`, so `{ i -> i.toLong() }` failed to compile there (J008).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/function_value_typing_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/function_value_typing_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.FunctionValueTypingSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val LIT_BYTE = 209u8

val LIT_LONG = 5000000000

val LIT_NAME = "lyric"

val SMALL: Int = 9

val SMALL_BYTE: Byte = 250u8

val SMALL_UINT: UInt = 4000000000u32

record Holder {
  n: Long
}

func applyT[T](f: in () -> T): T {
  f()
}

func applyPair[T](f: in () -> T, g: in () -> T): List[T] {
  val xs: List[T] = newList()
  xs.add(f())
  xs.add(g())
  xs
}

func callLong(f: in () -> Long): Long {
  f()
}

func applyIntToLong(x: in Int, f: in (Int) -> Long): Long {
  f(x)
}

func mapT[T, U](x: in T, f: in (T) -> U): U {
  f(x)
}

func sign(n: in Int): Int {
  if n < 0 {
    -1
  } else {
    1
  }
}

test "a generic call over a lambda reading an unannotated module val" {
  val b = applyT({ -> LIT_BYTE })
  assertEqual(toString(b), "209", "Byte")
  val big: Long = applyT({ -> LIT_LONG })
  assertEqual(toString(big), "5000000000", "Long")
  assertEqual(applyT({ -> LIT_NAME }), "lyric", "String")
  assertEqual(toString(applyT({ -> LIT_NAME.length })), "5", "a member of the val")
}

test "a generic call over a lambda ending in an if, a match or a block" {
  val flag = LIT_NAME.length > 2
  val l = applyT({ -> if flag { 7i64 } else { 8i64 } })
  assertEqual(toString(l + 1i64), "8", "if")
  val m = applyT({ -> match sign(-4) { case -1 -> 250u8; case _ -> 1u8 } })
  assertEqual(toString(m), "250", "match")
  val k = applyT({ -> val local = 3u8; local + LIT_BYTE })
  assertEqual(toString(k), "212", "block")
  val h = Holder(n = 11)
  val xs = applyPair({ -> h.n }, { -> if flag { LIT_LONG } else { 0i64 } })
  assertEqual(toString(xs[0] + xs[1]), "5000000011", "two lambdas")
}

test "a lambda body's value widens to the expected return type" {
  val f: () -> Long = { -> 5 }
  assertEqual(toString(f()), "5", "literal")
  val huge: () -> Long = { -> 3000000000 }
  assertEqual(toString(huge()), "3000000000", "Long-sized literal")
  val fi: () -> Long = { -> SMALL }
  assertEqual(toString(fi() * 1000000000i64), "9000000000", "Int value")
  val fb: () -> Int = { -> SMALL_BYTE }
  assertEqual(toString(fb() + 10), "260", "Byte value to Int")
  val fu: () -> ULong = { -> SMALL_UINT }
  assertEqual(toString(fu()), "4000000000", "UInt value to ULong zero-extends")
  val fl: () -> ULong = { -> 7u32 }
  assertEqual(toString(fl()), "7", "UInt literal to ULong")
  assertEqual(toString(callLong({ -> 12 })), "12", "a Long-returning parameter")
}

test "each branch and return of a lambda body widens" {
  val r: (Bool) -> Long = { c -> if c { 1 } else { 2 } }
  assertEqual(toString(r(true) + r(false)), "3", "if branches")
  val m: (Int) -> Long = { n -> match n { case 0 -> 10; case _ -> 20 } }
  assertEqual(toString(m(0) + m(1)), "30", "match arms")
  val q: (Bool) -> Long = { c -> if c { return 100 }; 200 }
  assertEqual(toString(q(true)), "100", "a return in a branch")
  assertEqual(toString(q(false)), "200", "the trailing value")
  val early: (Int) -> Long = { n -> if n > 0 { return n }; return 0 }
  assertEqual(toString(early(6) * 1000000000i64), "6000000000", "returns of an Int value")
}

test "an unannotated parameter has the expected parameter type" {
  val f: (Int) -> Long = { i -> i.toLong() * 1000000000i64 }
  assertEqual(toString(f(3)), "3000000000", "annotated binding")
  assertEqual(toString(applyIntToLong(4, { i -> i.toLong() + 1i64 })), "5", "call argument")
  assertEqual(toString(mapT(250u8, { b -> b.toInt() + 10 })), "260", "generic call argument")
  val widen: (Int) -> Long = { n -> n }
  assertEqual(toString(widen(7) * 1000000000i64), "7000000000", "a parameter widened to the return type")
  val s: (String) -> Int = { t -> t.length }
  assertEqual(toString(s("abcd")), "4", "a String parameter's member")
}

func signLabels(): Int {
  val g: (Int) -> String = { n -> if n > 0 { return "pos" }; "neg" };
  (g(1) + g(-1)).length
}

test "a return in a lambda body is checked against the lambda" {
  assertEqual(toString(signLabels()), "6", "a String lambda in an Int-returning function")
}
