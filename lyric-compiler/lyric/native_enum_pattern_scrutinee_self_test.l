//! native_enum_pattern_scrutinee_self_test.l - a bare enum case name in a `match` arm compares
//! against the scrutinee's own enum on --target native (#8421).
//!
//! Native erases an enum to its ordinal, so the arm `case Shared ->` used to be resolved
//! bundle-wide: the first enum declared with a case called `Shared` won, and a value of the other
//! enum was compared against the wrong ordinal and fell through every arm.  The type checker now
//! records the enum each such pattern matches and the pipeline qualifies the pattern with it, so
//! the scrutinee may be any expression: a field access, a call result, an inferred local, a
//! lambda parameter, or the payload of another case.
//!
//! `First` and `Second` both have `Shared` and `Other`, at different ordinals, so a pattern bound
//! to the wrong enum cannot pass by luck.
@test_module
package Lyric.NativeEnumPatternScrutineeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

enum First {
  case Alpha
  case Shared
  case Other
}

enum Second {
  case Shared
  case Other
  case Beta
}

record Holder {
  kind: Second
  first: First
}

func makeSecond(n: Int): Second {
  if n == 0 {
    Second.Shared
  } else if n == 1 {
    Second.Other
  } else {
    Second.Beta
  }
}

func nameOfField(h: in Holder): String {
  match h.kind {
    case Shared -> "shared"
    case Other -> "other"
    case Beta -> "beta"
  }
}

func nameOfFirstField(h: in Holder): String {
  match h.first {
    case Alpha -> "alpha"
    case Shared -> "shared"
    case Other -> "other"
  }
}

func nameOfCall(n: Int): String {
  match makeSecond(n) {
    case Shared -> "shared"
    case Other -> "other"
    case Beta -> "beta"
  }
}

func nameOfInferredLocal(n: Int): String {
  val k = makeSecond(n)
  match k {
    case Shared -> "shared"
    case Other -> "other"
    case Beta -> "beta"
  }
}

func nameOfOption(o: in Option[Second]): String {
  match o {
    case Some(Shared) -> "some shared"
    case Some(Other) -> "some other"
    case Some(Beta) -> "some beta"
    case None -> "none"
  }
}

func nameOfPair(a: in First, b: in Second): String {
  match (a, b) {
    case (Shared, Shared) -> "both shared"
    case (Shared, _) -> "first shared"
    case (_, Shared) -> "second shared"
    case _ -> "neither"
  }
}

test "a field access scrutinee compares against its own enum" {
  assertEqual(nameOfField(Holder(kind = Second.Shared, first = First.Alpha)), "shared", "Second.Shared")
  assertEqual(nameOfField(Holder(kind = Second.Other, first = First.Alpha)), "other", "Second.Other")
  assertEqual(nameOfField(Holder(kind = Second.Beta, first = First.Alpha)), "beta", "Second.Beta")
}

test "the first-declared enum still works through a field" {
  assertEqual(nameOfFirstField(Holder(kind = Second.Beta, first = First.Alpha)), "alpha", "First.Alpha")
  assertEqual(nameOfFirstField(Holder(kind = Second.Beta, first = First.Shared)), "shared", "First.Shared")
  assertEqual(nameOfFirstField(Holder(kind = Second.Beta, first = First.Other)), "other", "First.Other")
}

test "a call result scrutinee compares against its own enum" {
  assertEqual(nameOfCall(0), "shared", "call 0")
  assertEqual(nameOfCall(1), "other", "call 1")
  assertEqual(nameOfCall(2), "beta", "call 2")
}

test "an inferred local scrutinee compares against its own enum" {
  assertEqual(nameOfInferredLocal(0), "shared", "local 0")
  assertEqual(nameOfInferredLocal(1), "other", "local 1")
  assertEqual(nameOfInferredLocal(2), "beta", "local 2")
}

test "an enum nested in a constructor pattern compares against its own enum" {
  assertEqual(nameOfOption(Some(value = Second.Shared)), "some shared", "Some(Shared)")
  assertEqual(nameOfOption(Some(value = Second.Other)), "some other", "Some(Other)")
  assertEqual(nameOfOption(Some(value = Second.Beta)), "some beta", "Some(Beta)")
  assertEqual(nameOfOption(None), "none", "None")
}

test "enums inside a tuple pattern each compare against their own enum" {
  assertEqual(nameOfPair(First.Shared, Second.Shared), "both shared", "both")
  assertEqual(nameOfPair(First.Shared, Second.Beta), "first shared", "first")
  assertEqual(nameOfPair(First.Alpha, Second.Shared), "second shared", "second")
  assertEqual(nameOfPair(First.Other, Second.Other), "neither", "neither")
}

test "a lambda parameter scrutinee compares against its own enum" {
  val describe: (Second) -> String = { k: Second ->
    match k {
      case Shared -> "shared"
      case Other -> "other"
      case Beta -> "beta"
    }
  }
  assertEqual(describe(Second.Shared), "shared", "lambda Shared")
  assertEqual(describe(Second.Beta), "beta", "lambda Beta")
}

union Side {
  case Left(n: Int)
  case Right(n: Int)
  case Middle
}

func sideValue(s: in Side): Int {
  match s {
    case Left(n) | Right(n) -> n
    case Middle -> -1
  }
}

func isSharedOrOther(k: in Second): Bool {
  match k {
    case Shared | Other -> true
    case Beta -> false
  }
}

func smallOrBig(n: in Int): String {
  match n {
    case 1 | 2 | 3 -> "small"
    case 100 | 200 -> "big"
    case _ -> "other"
  }
}

func orInTuple(a: in First, b: in Second): String {
  match (a, b) {
    case (Shared | Other, Beta) -> "first shared or other, second beta"
    case (_, Shared | Other) -> "second shared or other"
    case _ -> "neither"
  }
}

test "an or-pattern over enum cases compares against the scrutinee's own enum" {
  assertTrue(isSharedOrOther(Second.Shared), "Shared")
  assertTrue(isSharedOrOther(Second.Other), "Other")
  assertFalse(isSharedOrOther(Second.Beta), "Beta")
}

test "an or-pattern over literals" {
  assertEqual(smallOrBig(2), "small", "2")
  assertEqual(smallOrBig(200), "big", "200")
  assertEqual(smallOrBig(7), "other", "7")
}

test "alternatives that bind the same name join their values" {
  assertEqualInt(sideValue(Left(n = 4)), 4, "Left")
  assertEqualInt(sideValue(Right(n = 9)), 9, "Right")
  assertEqualInt(sideValue(Middle), -1, "Middle")
}

test "an or-pattern nested in a tuple pattern" {
  assertEqual(orInTuple(First.Other, Second.Beta), "first shared or other, second beta", "nested first")
  assertEqual(orInTuple(First.Alpha, Second.Other), "second shared or other", "nested second")
  assertEqual(orInTuple(First.Alpha, Second.Beta), "neither", "neither")
}

union Label {
  case Short(text: String)
  case Long(text: String)
  case Blank
}

func labelText(l: in Label): String {
  match l {
    case Short(t) | Long(t) -> t + "!"
    case Blank -> "blank"
  }
}

test "alternatives binding a reference-typed name join it" {
  assertEqual(labelText(Short(text = "a")), "a!", "Short")
  assertEqual(labelText(Long(text = "b")), "b!", "Long")
  assertEqual(labelText(Blank), "blank", "Blank")
}
