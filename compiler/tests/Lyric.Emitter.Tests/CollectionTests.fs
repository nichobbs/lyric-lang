/// End-to-end tests for `Std.Collections` — bootstrap-grade growable
/// lists (`IntList` / `StringList` / `LongList`) and hash maps
/// (`StringIntMap` / `StringStringMap`).
///
/// Each type-parameterisation is its own concrete CLR class until
/// generics-over-FFI lands; the Lyric-side surface is monomorphised
/// (`addInt`, `getString`, …) accordingly.
module Lyric.Emitter.Tests.CollectionTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "intlist_add_and_get",
    """
package CL1
import Std.Collections

func main(): Unit {
  val xs = newIntList()
  addInt(xs, 10)
  addInt(xs, 20)
  addInt(xs, 30)
  println(intListLength(xs))
  println(getInt(xs, 0))
  println(getInt(xs, 1))
  println(getInt(xs, 2))
}
""",
    "3\n10\n20\n30"

    "intlist_set_overwrites",
    """
package CL2
import Std.Collections

func main(): Unit {
  val xs = newIntList()
  addInt(xs, 1)
  addInt(xs, 2)
  setInt(xs, 0, 99)
  println(getInt(xs, 0))
  println(getInt(xs, 1))
}
""",
    "99\n2"

    "intlist_contains_and_remove",
    """
package CL3
import Std.Collections

func main(): Unit {
  val xs = newIntList()
  addInt(xs, 5)
  addInt(xs, 7)
  addInt(xs, 9)
  if intListContains(xs, 7) { println("yes") }
  if not intListContains(xs, 4) { println("no-4") }
  intListRemoveAt(xs, 1)
  println(intListLength(xs))
  println(getInt(xs, 1))
}
""",
    "yes\nno-4\n2\n9"

    "intlist_to_slice_iterates",
    """
package CL4
import Std.Collections

func main(): Unit {
  val xs = newIntList()
  addInt(xs, 100)
  addInt(xs, 200)
  addInt(xs, 300)
  for v in intListToSlice(xs) {
    println(v)
  }
}
""",
    "100\n200\n300"

    "stringlist_add_and_get",
    """
package CL5
import Std.Collections

func main(): Unit {
  val xs = newStringList()
  addString(xs, "alpha")
  addString(xs, "beta")
  addString(xs, "gamma")
  for s in stringListToSlice(xs) {
    println(s)
  }
}
""",
    "alpha\nbeta\ngamma"

    "longlist_round_trip",
    """
package CL6
import Std.Core
import Std.Collections
import Std.Parse

func main(): Unit {
  val xs = newLongList()
  match tryParseLong("9000000000") {
    case Ok(v)  -> addLong(xs, v)
    case Err(_) -> println("err")
  }
  match tryParseLong("1") {
    case Ok(v)  -> addLong(xs, v)
    case Err(_) -> println("err")
  }
  println(longListLength(xs))
  println(getLong(xs, 0))
  println(getLong(xs, 1))
}
""",
    "2\n9000000000\n1"

    "stringintmap_put_get_has",
    """
package CL7
import Std.Collections

func main(): Unit {
  val m = newStringIntMap()
  putStringInt(m, "alice", 30)
  putStringInt(m, "bob", 25)
  println(stringIntMapLength(m))
  if hasStringIntKey(m, "alice") {
    println(getStringIntRaw(m, "alice"))
  }
  if not hasStringIntKey(m, "carol") {
    println("missing")
  }
}
""",
    "2\n30\nmissing"

    "stringintmap_overwrite_and_remove",
    """
package CL8
import Std.Collections

func main(): Unit {
  val m = newStringIntMap()
  putStringInt(m, "x", 1)
  putStringInt(m, "x", 2)
  println(getStringIntRaw(m, "x"))
  if removeStringIntKey(m, "x") { println("removed") }
  println(stringIntMapLength(m))
}
""",
    "2\nremoved\n0"

    "stringstringmap_keys_iterate",
    """
package CL9
import Std.Collections

func main(): Unit {
  val m = newStringStringMap()
  putStringString(m, "host", "example.com")
  putStringString(m, "port", "443")
  println(stringStringMapLength(m))
  if hasStringStringKey(m, "host") {
    println(getStringStringRaw(m, "host"))
  }
}
""",
    "2\nexample.com"

    "intlist_dedup_via_map",
    // Practical test: build a deduplicated string list using the map
    // as a "have I seen this?" set.  Exercises both collection types
    // in the same program.
    """
package CL10
import Std.Collections

func main(): Unit {
  val seen = newStringIntMap()
  val outxs = newStringList()
  val raw  = ["a", "b", "a", "c", "b", "d"]
  for s in raw {
    if not hasStringIntKey(seen, s) {
      putStringInt(seen, s, 1)
      addString(outxs, s)
    }
  }
  for s in stringListToSlice(outxs) {
    println(s)
  }
}
""",
    "a\nb\nc\nd"
]

let tests =
    testSequenced
    <| testList "Std.Collections (IntList / StringList / *Map)" (cases |> List.map mk)
