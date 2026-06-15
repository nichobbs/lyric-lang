//! Test program for pattern matching generic union types issue #3705

package Test

import Std.Core

func testResultPattern(r: Result[Int, String]): Int {
  match r {
    case Ok(value) -> value
    case Err(msg) -> 0
  }
}

func testNestedPattern(r: Result[Option[Int], String]): Int {
  match r {
    case Ok(someValue) -> {
      match someValue {
        case Some(i) -> i
        case None -> 0
      }
    }
    case Err(msg) -> 0
  }
}

func testRecordWithGenericUnion(): Int {
  val opt: Option[Int] = Some(42)
  match opt {
    case Some(v) -> v
    case None -> 0
  }
}

func main(): Int {
  val r1: Result[Int, String] = Ok(42)
  val result1 = testResultPattern(r1)
  if result1 == 42 { 0 } else { 1 }
}
