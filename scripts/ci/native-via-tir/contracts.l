//! contracts.l - contract clauses and `?` lowered on TIR (docs/70 phase 4a part 6, D502, D503): `requires:` and
//! `ensures:` are asserts in the body, `?` is a match with an early return, both before the bundle is
//! monomorphised.  Every function lowers from TIR and prints what the AST path prints;
//! `native-via-tir-e2e.sh` also compiles a violated clause and compares the panic message.
package ContractsViaTir

import Std.Core
import Std.Console as Console

func half(n: in Int): Int
  requires: n >= 0
  ensures: result <= n
{
  n / 2
}

func clamp(n: in Int, lo: in Int, hi: in Int): Int
  requires: lo <= hi
  ensures: result >= lo and result <= hi
{
  if n < lo {
    return lo
  }
  if n > hi {
    return hi
  }
  n
}

func parse(s: in String): Result[Int, String] {
  if s == "x" { Err(error = "bad") } else { Ok(value = 7) }
}

func twice(s: in String): Result[Int, String] {
  val a = parse(s)?
  Ok(value = a * 2)
}

func first(a: in Option[Int], b: in Option[Int]): Option[Int] {
  val x = a?
  val y = b?
  Some(value = x + y)
}

func main(): Unit {
  println(toString(half(10)))
  println(toString(clamp(15, 0, 10)))
  println(toString(clamp(0 - 3, 0, 10)))
  println(toString(clamp(4, 0, 10)))
  match twice("ok") {
    case Ok(v) -> println(toString(v))
    case Err(e) -> println(e)
  }
  match twice("x") {
    case Ok(v) -> println(toString(v))
    case Err(e) -> println(e)
  }
  match first(Some(value = 1), Some(value = 2)) {
    case Some(v) -> println(toString(v))
    case None -> println("none")
  }
  match first(Some(value = 1), None) {
    case Some(v) -> println(toString(v))
    case None -> println("none")
  }
}
