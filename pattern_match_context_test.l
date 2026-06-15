//! Test: Pattern matching context type arguments for generic unions.
//! This test verifies that when pattern matching on a generic union parameter,
//! the nested constructor calls use the correct type arguments from the scrutinee,
//! not the function's return type.

@test_module
package PatternMatchContextTest

import Std.Core
import Std.Testing

// Test case 1: Pattern match on Result[Int, String] parameter with nested Some(v)
func testPatternMatchResultWithNestedOption(): Unit {
  func processResult(x: Result[Int, String]): Option[Int] {
    match x {
      case Ok(v) -> Some(v)  // <- v: Int, Some(v) should construct Option[Int]
      case Err(_) -> None
    }
  }

  // Test that the function returns the correct type
  val r1: Result[Int, String] = Ok(42)
  val o1: Option[Int] = processResult(r1)
  match o1 {
    case Some(n) -> assertTrue(n == 42, "pattern match should extract 42")
    case None -> fail("expected Some(42), got None")
  }

  val r2: Result[Int, String] = Err("error")
  val o2: Option[Int] = processResult(r2)
  match o2 {
    case Some(_) -> fail("expected None for error case")
    case None -> () // success
  }
}

// Test case 2: Nested pattern matching with multiple generic union types
func testNestedPatternMatchMultipleUnions(): Unit {
  func processResultPair(
    x: Result[Int, String],
    y: Result[Bool, String]
  ): String {
    match x {
      case Ok(v1) -> {
        match y {
          case Ok(v2) -> "ok: " + (if v2 { "true" } else { "false" })
          case Err(e) -> "err_y: " + e
        }
      }
      case Err(e) -> "err_x: " + e
    }
  }

  val r1: Result[Int, String] = Ok(10)
  val r2: Result[Bool, String] = Ok(true)
  val result = processResultPair(r1, r2)
  assertTrue(result == "ok: true", "nested pattern match should work correctly")
}

// Test case 3: Pattern match with constructor in arm body (not part of pattern)
func testPatternMatchWithBodyConstructor(): Unit {
  func wrapOption(x: Result[String, Int]): Option[String] {
    match x {
      case Ok(s) -> Some(s)  // <- s: String, Some(s) should be Option[String]
      case Err(_) -> None
    }
  }

  val r1: Result[String, Int] = Ok("hello")
  val o1: Option[String] = wrapOption(r1)
  match o1 {
    case Some(s) -> assertTrue(s == "hello", "should extract string correctly")
    case None -> fail("expected Some, got None")
  }
}

// Test case 4: Pattern matching on Result with generic parameter inference
func testPatternMatchWithGenericInference(): Unit {
  func transformResult[T](x: Result[T, String]): Option[T] {
    match x {
      case Ok(v) -> Some(v)  // <- v: T, Some(v) should be Option[T]
      case Err(_) -> None
    }
  }

  val ri: Result[Int, String] = Ok(99)
  val oi: Option[Int] = transformResult(ri)
  match oi {
    case Some(n) -> assertTrue(n == 99, "int generic case should work")
    case None -> fail("expected Some, got None")
  }

  val rb: Result[Bool, String] = Ok(false)
  val ob: Option[Bool] = transformResult(rb)
  match ob {
    case Some(b) -> assertTrue(not b, "bool generic case should work")
    case None -> fail("expected Some, got None")
  }
}

// Test case 5: Multiple arms with nested constructors
func testMultipleArmsWithConstructors(): Unit {
  func classifyError(x: Result[Int, String]): String {
    match x {
      case Ok(v) -> {
        // Each constructor in different arms should have correct context
        if v > 100 {
          "big"
        } else if v > 50 {
          "medium"
        } else {
          "small"
        }
      }
      case Err(_) -> "error"
    }
  }

  val r1: Result[Int, String] = Ok(150)
  assertTrue(classifyError(r1) == "big", "should classify 150 as big")

  val r2: Result[Int, String] = Ok(75)
  assertTrue(classifyError(r2) == "medium", "should classify 75 as medium")

  val r3: Result[Int, String] = Ok(25)
  assertTrue(classifyError(r3) == "small", "should classify 25 as small")
}

func main(): Int {
  testPatternMatchResultWithNestedOption()
  testNestedPatternMatchMultipleUnions()
  testPatternMatchWithBodyConstructor()
  testPatternMatchWithGenericInference()
  testMultipleArmsWithConstructors()
  0
}
