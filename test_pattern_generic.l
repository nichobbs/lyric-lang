//! Test for pattern matching generic union type context fix
//  Tests that ExpectedType is properly preserved during pattern binding
//  so nullary union cases get the correct generic type args (issue #3705)

package Test

import Std.Core

func testResultPattern(r: Result[Int, String]): Int {
  match r {
    case Ok(value) -> value
    case Err(msg) -> 0
  }
}

func testOptionPattern(opt: Option[String]): String {
  match opt {
    case Some(s) -> s
    case None -> ""
  }
}

func testNestedResultPattern(r: Result[Option[Int], String]): Int {
  match r {
    case Ok(optVal) -> {
      match optVal {
        case Some(i) -> i
        case None -> 0
      }
    }
    case Err(_) -> -1
  }
}

func testTuplePattern(t: (Int, String)): String {
  match t {
    case (_, s) -> s
  }
}

func testOrPattern(x: Option[Int]): Int {
  match x {
    case Some(i) -> i
    case None -> 0
  }
}

func main(): Int {
  // Test 1: Result[Int, String] pattern
  val r1: Result[Int, String] = Ok(42)
  val res1 = testResultPattern(r1)
  if res1 != 42 { return 1 }

  // Test 2: Option[String] pattern
  val opt1: Option[String] = Some("hello")
  val opt1Result = testOptionPattern(opt1)
  if opt1Result != "hello" { return 2 }

  val opt2: Option[String] = None
  val opt2Result = testOptionPattern(opt2)
  if opt2Result != "" { return 3 }

  // Test 3: Nested patterns
  val nested: Result[Option[Int], String] = Ok(Some(99))
  val nestedRes = testNestedResultPattern(nested)
  if nestedRes != 99 { return 4 }

  // Test 4: Tuple pattern
  val tup = (123, "world")
  val tupRes = testTuplePattern(tup)
  if tupRes != "world" { return 5 }

  // Test 5: Or pattern
  val or1: Option[Int] = Some(55)
  val orRes1 = testOrPattern(or1)
  if orRes1 != 55 { return 6 }

  val or2: Option[Int] = None
  val orRes2 = testOrPattern(or2)
  if orRes2 != 0 { return 7 }

  0  // All tests passed
}
