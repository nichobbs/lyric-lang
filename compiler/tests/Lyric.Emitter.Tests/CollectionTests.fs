/// End-to-end tests for `Std.Collections` — generic growable lists
/// (`List[T]`) and hash maps (`Map[K, V]`), both backed by BCL
/// generics via the FFI.
///
/// Most operations come from BCL method dispatch (`xs.add`, `xs[i]`,
/// `m.containsKey`, `m[k]`, `m.count`).  The Lyric-side surface only
/// adds the constructor (`newList` / `newMap`) and `mapGet` returning
/// `Option[V]` (which would otherwise need out-params).
module Lyric.Emitter.Tests.CollectionTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "list_int_method_style",
    """
package CL1
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  println(xs.count)
  println(xs[0])
  println(xs[1])
  println(xs[2])
}
""",
    "3\n10\n20\n30"

    "list_int_contains_remove",
    """
package CL2
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(5)
  xs.add(7)
  xs.add(9)
  if xs.contains(7) { println("yes") }
  if not xs.contains(4) { println("no-4") }
  xs.removeAt(1)
  println(xs.count)
  println(xs[1])
}
""",
    "yes\nno-4\n2\n9"

    "list_int_to_array_iterates",
    """
package CL3
import Std.Collections

func main(): Unit {
  val xs: List[Int] = newList()
  xs.add(100)
  xs.add(200)
  xs.add(300)
  for v in xs.toArray() {
    println(v)
  }
}
""",
    "100\n200\n300"

    "list_string_basic",
    """
package CL4
import Std.Collections

func main(): Unit {
  val xs: List[String] = newList()
  xs.add("alpha")
  xs.add("beta")
  xs.add("gamma")
  for s in xs.toArray() {
    println(s)
  }
}
""",
    "alpha\nbeta\ngamma"

    "list_long_round_trip",
    """
package CL5
import Std.Core
import Std.Collections
import Std.Parse

func main(): Unit {
  val xs: List[Long] = newList()
  match tryParseLong("9000000000") {
    case Ok(v)  -> xs.add(v)
    case Err(_) -> println("err")
  }
  match tryParseLong("1") {
    case Ok(v)  -> xs.add(v)
    case Err(_) -> println("err")
  }
  println(xs.count)
  println(xs[0])
  println(xs[1])
}
""",
    "2\n9000000000\n1"

    "map_string_int_basic",
    """
package CL6
import Std.Core
import Std.Collections

func main(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("alice", 30)
  m.add("bob", 25)
  println(m.count)
  match mapGet(m, "alice") {
    case Some(v) -> println(v)
    case None    -> println("missing")
  }
  match mapGet(m, "carol") {
    case Some(v) -> println(v)
    case None    -> println("missing")
  }
}
""",
    "2\n30\nmissing"

    "map_remove_and_index",
    """
package CL7
import Std.Collections

func main(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("x", 1)
  println(m["x"])
  if m.remove("x") { println("removed") }
  println(m.count)
}
""",
    "1\nremoved\n0"

    "map_string_string_get_via_option",
    """
package CL8
import Std.Core
import Std.Collections

func main(): Unit {
  val m: Map[String, String] = newMap()
  m.add("host", "example.com")
  m.add("port", "443")
  println(m.count)
  match mapGet(m, "host") {
    case Some(v) -> println(v)
    case None    -> println("missing")
  }
}
""",
    "2\nexample.com"

    // End-to-end: build a deduplicated string list using a `Map[String, Int]`
    // as a "have I seen this?" set.  Exercises both generic types in
    // the same program with method-style dispatch.
    "list_dedup_via_map",
    """
package CL9
import Std.Collections

func main(): Unit {
  val seen: Map[String, Int] = newMap()
  val outxs: List[String] = newList()
  val raw  = ["a", "b", "a", "c", "b", "d"]
  for s in raw {
    if not seen.containsKey(s) {
      seen.add(s, 1)
      outxs.add(s)
    }
  }
  for s in outxs.toArray() {
    println(s)
  }
}
""",
    "a\nb\nc\nd"
]

let tests =
    testSequenced
    <| testList "Std.Collections (generic List / Map via BCL dispatch)"
                (cases |> List.map mk)
