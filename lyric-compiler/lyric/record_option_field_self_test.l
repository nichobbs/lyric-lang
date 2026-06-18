//! A `None` / `Some(...)` value for a concrete `Option[T]` record field must
//! instantiate with the field's type argument, so a later `match` on the field
//! finds the right arm (D-progress-359 / #1731).
@test_module
package Lyric.RecordOptionFieldSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Mirrors a many-Option-field record (the shape that surfaced the bug while
// investigating mono's FunctionDecl construction): several `Option` fields
// interspersed with List / Bool / String / Int, a mix of `None` and `Some`.
record FD {
  docs: List[String]
  anns: List[String]
  vis: Option[String]
  isAsync: Bool
  name: String
  generics: Option[String]
  ret: Option[String]
  whereC: Option[String]
  contracts: List[String]
  body: Option[String]
  span: Int
}

func optTag(o: in Option[String]): Int {
  match o {
    case None -> 0
    case Some(_) -> 1
  }
}

test "None-valued option fields read back as None, Some as Some" {
  val f = FD(
    docs = newList(),
    anns = newList(),
    vis = None,
    isAsync = false,
    name = "n",
    generics = None,
    ret = Some(value = "Int"),
    whereC = None,
    contracts = newList(),
    body = None,
    span = 0
  )
  assertEqualInt(optTag(f.vis), 0, "vis None")
  assertEqualInt(optTag(f.generics), 0, "generics None")
  assertEqualInt(optTag(f.ret), 1, "ret Some")
  assertEqualInt(optTag(f.whereC), 0, "whereC None")
  assertEqualInt(optTag(f.body), 0, "body None")
}

test "Some payload on an option field round-trips its value" {
  val f = FD(
    docs = newList(),
    anns = newList(),
    vis = Some(value = "pub"),
    isAsync = true,
    name = "m",
    generics = None,
    ret = Some(value = "String"),
    whereC = None,
    contracts = newList(),
    body = Some(value = "x"),
    span = 7
  )
  match f.ret {
    case None -> assertTrue(false, "ret should be Some")
    case Some(v) -> assertEqual(v, "String", "ret value")
  }
  match f.vis {
    case None -> assertTrue(false, "vis should be Some")
    case Some(v) -> assertEqual(v, "pub", "vis value")
  }
}

// Option[Int] (non-String inner) guards against type-arg erasure on the
// integer path.
record Box {
  tag: Int
  v: Option[Int]
}

test "Option[Int] field None / Some round-trip" {
  val b1 = Box(tag = 1, v = None)
  match b1.v {
    case None -> assertTrue(true, "b1 None")
    case Some(_) -> assertTrue(false, "b1 should be None")
  }
  val b2 = Box(tag = 2, v = Some(value = 9))
  match b2.v {
    case None -> assertTrue(false, "b2 should be Some")
    case Some(n) -> assertEqualInt(n, 9, "b2 value")
  }
}
