//! A generic call passed straight to another generic, with nothing but the
//! outer call's expected type to bind its type parameter:
//! `keyed("k", paragraph("p"))` specialised `paragraph` at `Object`, and
//! storing the result in a `List[View[Msg]]` failed with
//! `ArrayTypeMismatchException` on dotnet.  `lyric test <file>` cannot build
//! the imported case, so this is a project.
@test_module
package NestedTests

import Std.Core
import Std.Collections
import Std.Testing
import NestedLib.{View, paragraph, keyed, keyOf}

union Msg {
  case Other
}

test "a nested generic argument in an annotated binding" {
  val kids: List[View[Msg]] = newList()
  val outcomes: View[Msg] = keyed("outcomes", paragraph("Outcomes"))
  kids.add(outcomes)
  assertEqualInt(kids.count, 1, "the view is stored")
  assertEqual(keyOf(kids[0]), "outcomes", "keyed")
}

test "a nested generic argument passed to List.add" {
  val kids: List[View[Msg]] = newList()
  kids.add(keyed("summary", paragraph("Summary")))
  kids.add(keyed("outer", keyed("inner", paragraph("Both"))))
  assertEqualInt(kids.count, 2, "both views are stored")
  assertEqual(keyOf(kids[0]), "summary", "first key")
  assertEqual(keyOf(kids[1]), "outer", "outer key wins")
}

func summary(): View[Msg] {
  keyed("returned", paragraph("Returned"))
}

test "a nested generic argument in a return position" {
  val kids: List[View[Msg]] = newList()
  kids.add(summary())
  assertEqual(keyOf(kids[0]), "returned", "returned key")
}
