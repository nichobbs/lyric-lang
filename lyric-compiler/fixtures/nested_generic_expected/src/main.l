//! Executable form of tests/nested_tests.l for `--target native`, whose
//! `lyric test` does not run manifest (multi-package) suites.  Built and run by
//! scripts/ci/nested-generic-expected-test.sh.
package NestedMain

import Std.Core
import Std.Collections
import Std.Console
import NestedLib.{View, paragraph, keyed, keyOf}

union Msg {
  case Other
}

func check(ok: in Bool, label: in String): Unit {
  if not ok {
    panic("FAIL: " + label)
  }
}

func summary(): View[Msg] {
  keyed("returned", paragraph("Returned"))
}

func main(): Unit {
  val kids: List[View[Msg]] = newList()
  val outcomes: View[Msg] = keyed("outcomes", paragraph("Outcomes"))
  kids.add(outcomes)
  kids.add(keyed("summary", paragraph("Summary")))
  kids.add(keyed("outer", keyed("inner", paragraph("Both"))))
  kids.add(summary())
  check(kids.count == 4, "every view is stored")
  check(keyOf(kids[0]) == "outcomes", "annotated binding")
  check(keyOf(kids[1]) == "summary", "List.add argument")
  check(keyOf(kids[2]) == "outer", "doubly nested keyed")
  check(keyOf(kids[3]) == "returned", "return position")
  println("nested-generic-expected: ok")
}
