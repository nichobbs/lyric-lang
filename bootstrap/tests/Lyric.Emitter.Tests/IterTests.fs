/// End-to-end tests for the allocating helpers in `Std.Iter`
/// (`map`, `filter`, `take`, `drop`, `concat`).  Non-allocating
/// helpers (`forEach`, `fold`, `any`, `all`, `count`, `find`,
/// `sumInt`) are covered by the worked examples in
/// `docs/02-worked-examples.md` and exercised indirectly through
/// the surrounding test suite.
module Lyric.Emitter.Tests.IterTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "iter_map_doubles_ints",
    """
package IT1
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2, 3]
  val ys = map(xs, { n: Int -> n * 2 })
  for y in ys { println(y) }
}
""",
    "2\n4\n6"

    "iter_filter_keeps_evens",
    """
package IT2
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2, 3, 4, 5, 6]
  val evens = filter(xs, { n: Int -> n % 2 == 0 })
  for y in evens { println(y) }
}
""",
    "2\n4\n6"

    "iter_take_first_n",
    """
package IT3
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [10, 20, 30, 40]
  val first2 = take(xs, 2)
  for y in first2 { println(y) }
}
""",
    "10\n20"

    "iter_take_clamps_to_length",
    """
package IT4
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2]
  val ys = take(xs, 99)
  for y in ys { println(y) }
}
""",
    "1\n2"

    "iter_drop_skips_n",
    """
package IT5
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [10, 20, 30, 40]
  val ys = drop(xs, 2)
  for y in ys { println(y) }
}
""",
    "30\n40"

    "iter_drop_more_than_length_yields_empty",
    """
package IT6
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2]
  val ys = drop(xs, 99)
  println(ys.length)
}
""",
    "0"

    "iter_concat_two_slices",
    """
package IT7
import Std.Iter

func main(): Unit {
  val a: slice[Int] = [1, 2]
  val b: slice[Int] = [3, 4, 5]
  val both = concat(a, b)
  for y in both { println(y) }
}
""",
    "1\n2\n3\n4\n5"

    "iter_map_filter_chain",
    """
package IT8
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2, 3, 4, 5]
  val ys = filter(map(xs, { n: Int -> n * n }), { n: Int -> n > 5 })
  for y in ys { println(y) }
}
""",
    "9\n16\n25"

    "iter_map_to_strings",
    """
package IT9
import Std.Iter

func main(): Unit {
  val xs: slice[Int] = [1, 2, 3]
  val ss = map(xs, { n: Int -> toString(n) })
  for s in ss { println(s) }
}
""",
    "1\n2\n3"

    "iter_sumLong",
    """
package I7
import Std.Core
import Std.Iter
func main(): Unit {
  println(toString(sumLong([1i64, 2i64, 3i64])))
}
""",
    "6"

    "iter_iterMaxInt",
    """
package I8
import Std.Core
import Std.Iter
func main(): Unit {
  match iterMaxInt([3, 1, 4, 1, 5, 9, 2, 6]) {
    case None -> println("empty")
    case Some(v) -> println(toString(v))
  }
}
""",
    "9"

    "iter_iterMinInt_empty",
    """
package I9
import Std.Core
import Std.Iter
func main(): Unit {
  val xs: slice[Int] = []
  match iterMinInt(xs) {
    case None -> println("empty")
    case Some(v) -> println(toString(v))
  }
}
""",
    "empty"

    "iter_reverse",
    """
package I10
import Std.Core
import Std.Iter
func main(): Unit {
  val r = reverse([1, 2, 3])
  for x in r { println(toString(x)) }
}
""",
    "3\n2\n1"
]

let tests =
    testSequenced
    <| testList "Std.Iter (allocating helpers)"
                (cases |> List.map mk)
