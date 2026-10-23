//! Executable form of tests/override_tests.l for `--target native`, whose
//! `lyric test` does not run manifest (multi-package) suites.  Built and run by
//! scripts/ci/builtin-name-override-test.sh.
package OverrideMain

import Std.Core
import Std.Console
import Std.Collections.{newMap}
import OverrideLib
import OverrideLib.{newList}

func check(ok: in Bool, label: in String): Unit {
  if not ok {
    panic("FAIL: " + label)
  }
}

func main(): Unit {
  check(newList(3) == 3000, "imported newList overrides the builtin intrinsic")
  check(OverrideLib.mapGet(4, 2) == 402, "imported different-arity mapGet lowers")
  val m: Map[String, Int] = newMap()
  m.add("a", 10)
  check(m.containsKey("a") and m.count == 1, "bare newMap() still uses the intrinsic")
  println("builtin-name-override: ok")
}
