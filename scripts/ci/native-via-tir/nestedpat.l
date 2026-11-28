//! nestedpat.l - a case pattern under another case pattern (`Err(Malformed(m))`), lowered from TIR (docs/70
//! phase 4a): the inner union is opened on the payload, its discriminant tested and its bindings stored.
//! `native-via-tir-e2e.sh` runs it both ways and checks that nothing falls back to the AST path.
package NestedPatViaTir

import Std.Core
import Std.Console as Console

union Failure {
  case Unsupported(why: String)
  case Malformed(at: Int, why: String)
}

func describe(r: in Result[Int, Failure]): String {
  match r {
    case Ok(v) -> "ok " + toString(v)
    case Err(Unsupported(why)) -> "unsupported " + why
    case Err(Malformed(at, why)) -> "malformed " + toString(at) + " " + why
  }
}

func code(r: in Result[Int, Failure]): Int {
  match r {
    case Err(Unsupported(_)) -> 1
    case Err(Malformed(_, _)) -> 2
    case Ok(_) -> 0
  }
}

func main(): Unit {
  val a: Result[Int, Failure] = Ok(5)
  val b: Result[Int, Failure] = Err(Unsupported("native"))
  val c: Result[Int, Failure] = Err(Malformed(3, "bad"))
  Console.println(describe(a))
  Console.println(describe(b))
  Console.println(describe(c))
  Console.println(toString(code(a) * 100 + code(b) * 10 + code(c)))
}
