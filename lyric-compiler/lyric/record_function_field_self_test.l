//! record_function_field_self_test.l — runtime tests for calling the function
//! held in a record's function-typed field, `r.f(args)` (D-progress-952).
//! Both backends used to lower the call as a method on the record: MSIL
//! emitted a run-time "unsupported method" throw and the JVM an
//! `invokevirtual` against a method that does not exist.  Runs on both
//! targets:
//!   lyric test lyric-compiler/lyric/record_function_field_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/record_function_field_self_test.l
@test_module
package RecordFunctionFieldSelfTest

import Std.Core
import Std.Testing

enum AccessCode {
  case Granted
  case PermissionDenied
  case Other
}

func accessCodeOf(n: in Int): AccessCode {
  match n {
    case 0 -> AccessCode.Granted
    case 7 -> AccessCode.PermissionDenied
    case _ -> AccessCode.Other
  }
}

record Handler {
  apply: (Int) -> Int
}

record Sink {
  log: List[String]
  push: (String) -> Unit
}

record Classifier[T] {
  classify: (T) -> Option[T]
}

record Named {
  label: String
  shout: (String) -> String
  func shoutLabel(self: in Named): String {
    self.label + "!"
  }
}

test "a record's function field is called with its arguments" {
  val h = Handler(apply = { x: Int -> x + 1 })
  assertEqualInt(h.apply(2), 3, "h.apply(2)")
}

test "a function field's result takes part in arithmetic" {
  val h = Handler(apply = { x: Int -> x * 10 })
  assertEqualInt(h.apply(3) + h.apply(1), 40, "30 + 10")
}

test "a Unit-returning function field runs for its effect" {
  val seen: List[String] = newList()
  val s = Sink(log = seen, push = { m: String -> seen.add(m) })
  s.push("a")
  s.push("b")
  assertEqualInt(seen.count, 2, "two pushes")
  assertEqual(seen[1], "b", "second push")
}

test "a generic record's function field result is matched" {
  val c: Classifier[Int] = Classifier(classify = { x: Int -> if x > 0 { Some(value = x) } else { None } })
  match c.classify(4) {
    case Some(v) -> assertEqualInt(v, 4, "positive kept")
    case None -> assertTrue(false, "expected Some")
  }
  match c.classify(-1) {
    case Some(_) -> assertTrue(false, "expected None")
    case None -> assertTrue(true, "negative dropped")
  }
}

test "a method is still called as a method next to function fields" {
  val n = Named(label = "hey", shout = { s: String -> s + "?" })
  assertEqual(n.shoutLabel(), "hey!", "method")
  assertEqual(n.shout("x"), "x?", "field function")
}

// An enum case sharing its name with a union case elsewhere in the bundle
// (`Std.Errors`' `PermissionDenied(path)`) matches as the enum: the pattern
// binds nothing and must not be cast to the union's case class.
test "an enum case named like another package's union case matches as the enum" {
  val label = match accessCodeOf(7) {
    case AccessCode.PermissionDenied -> "denied"
    case AccessCode.Granted -> "granted"
    case _ -> "other"
  }
  assertEqual(label, "denied", "enum case matched")
}
