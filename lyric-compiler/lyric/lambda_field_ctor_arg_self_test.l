//! lambda_field_ctor_arg_self_test.l — a lambda passed as a record
//! constructor argument returns the field's declared result type (#7835).
//!
//! On `--target dotnet` a lambda whose body is a bare `None` (or `Some(x)`,
//! `Ok(x)`, `Err(e)`) has no type of its own to construct: codegen takes the
//! case class's type arguments from the lambda's recorded result type.  A
//! lambda written directly as a constructor argument had none recorded, so it
//! built `Option_None<object>` and the caller's cast to the field's
//! `Option<string>` threw `InvalidCastException`.  The lambda's result type
//! is now seeded from the field's function type, substituted with the
//! instantiation's type arguments for a generic record.
//!
//! A bare call to such a field from a member body reaches the field before a
//! same-named top-level function (docs/01 §2.4).
//!
//! Runs on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/lambda_field_ctor_arg_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/lambda_field_ctor_arg_self_test.l
@test_module
package LambdaFieldCtorArgTest

import Std.Core
import Std.Testing

record Picker {
  pick: (Int) -> Option[String]
}

record Parser {
  parse: (String) -> Result[Int, String]
}

record Mapper[A, B] {
  label: String
  apply: (A) -> Option[B]
}

union Shape {
  case Circle(r: Int)
  case Square(side: Int)
}

record Classifier {
  classify: (Int) -> Option[Shape]
}

func pickFrom(p: in Picker, n: in Int): String {
  match p.pick(n) {
    case Some(s) -> s
    case None -> "none"
  }
}

func applyMapper[A, B](m: in Mapper[A, B], a: in A): Option[B] {
  m.apply(a)
}

test "a named-argument lambda returning bare None" {
  val p = Picker(pick = { _: Int -> None })
  assertEqual(pickFrom(p, 1), "none", "None through the field")
}

test "a named-argument lambda returning Some" {
  val p = Picker(pick = { n: Int -> if n > 5 { Some(value = "big") } else { Some(value = "small") } })
  assertEqual(pickFrom(p, 7), "big", "Some through the field")
  assertEqual(pickFrom(p, 2), "small", "Some through the field")
}

test "a lambda returning Ok or Err" {
  val p = Parser(parse = { s: String -> if s == "" { Err(error = "empty") } else { Ok(value = 1) } })
  match p.parse("") {
    case Ok(_) -> assertTrue(false, "empty input parsed")
    case Err(e) -> assertEqual(e, "empty", "Err payload")
  }
  match p.parse("x") {
    case Ok(v) -> assertEqualInt(v, 1, "Ok payload")
    case Err(_) -> assertTrue(false, "non-empty input rejected")
  }
}

test "a generic record's lambda field returning bare None" {
  val m: Mapper[Int, String] = Mapper(label = "never", apply = { _: Int -> None })
  assertTrue(applyMapper(m, 3).isNone, "None through a generic field")
  assertEqual(m.label, "never", "other field intact")
}

test "a lambda returning a union case wrapped in Some" {
  val c = Classifier(classify = { n: Int -> if n > 0 { Some(value = Circle(r = n)) } else { None } })
  match c.classify(4) {
    case Some(Circle(r)) -> assertEqualInt(r, 4, "radius")
    case Some(Square(_)) -> assertTrue(false, "wrong case")
    case None -> assertTrue(false, "positive classified as None")
  }
  assertTrue(c.classify(0).isNone, "non-positive is None")
}

func choose(n: in Int): Option[String] {
  if n > 0 {
    Some(value = "top-level")
  } else {
    None
  }
}

record Shadow {
  choose: (Int) -> Option[String]
  func viaBare(self: in Shadow, n: in Int): String {
    match choose(n) {
      case Some(s) -> s
      case None -> "none"
    }
  }
}

record ShadowOf[T] {
  choose: (Int) -> Option[T]
  func viaBare(self: in ShadowOf[T], n: in Int): Option[T] {
    choose(n)
  }
}

// A bare name in a member body means the enclosing type's field before a
// same-named top-level function (docs/01 §2.4, #6173).
test "a bare call in a record method reaches the field, not a same-named function" {
  val r = Shadow(choose = { _: Int -> Some(value = "field") })
  assertEqual(r.viaBare(1), "field", "bare call")
  match choose(1) {
    case Some(s) -> assertEqual(s, "top-level", "free function")
    case None -> assertTrue(false, "the free function returned Some")
  }
}

// Inside a generic record the field's type names a type parameter, so the
// call reaches the backend as written rather than through a typed local.
test "a bare call in a generic record method reaches the field" {
  val r: ShadowOf[String] = ShadowOf(choose = { _: Int -> Some(value = "field") })
  match r.viaBare(1) {
    case Some(s) -> assertEqual(s, "field", "bare call")
    case None -> assertTrue(false, "the field returned Some")
  }
  val none: ShadowOf[String] = ShadowOf(choose = { _: Int -> None })
  assertTrue(none.viaBare(1).isNone, "None through the field")
}

protected type ShadowCell[T] {
  var choose: (Int) -> Option[T]
  func pick(n: in Int): Option[T] {
    choose(n)
  }
}

test "a bare call in a generic protected type reaches the field" {
  val c: ShadowCell[String] = ShadowCell(choose = { _: Int -> Some(value = "field") })
  match c.pick(1) {
    case Some(s) -> assertEqual(s, "field", "bare call")
    case None -> assertTrue(false, "the field returned Some")
  }
}
