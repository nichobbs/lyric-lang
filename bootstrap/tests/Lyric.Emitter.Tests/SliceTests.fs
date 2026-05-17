module Lyric.Emitter.Tests.SliceTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    "list_first",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[0])
}
""",
    "10"

    "list_last",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[2])
}
""",
    "30"

    "list_length",
    """
package E7
func main(): Unit {
  val a = [1, 2, 3, 4, 5]
  println(a.length)
}
""",
    "5"

    "list_string_elements",
    """
package E7
func main(): Unit {
  val xs = ["a", "b", "c"]
  println(xs[1])
}
""",
    "b"

    "for_in_array",
    """
package E7
func main(): Unit {
  val xs = [1, 2, 3, 4]
  var sum = 0
  for x in xs { sum += x }
  println(sum)
}
""",
    "10"

    "list_index_in_arithmetic",
    """
package E7
func main(): Unit {
  val a = [10, 20, 30]
  println(a[0] + a[1] + a[2])
}
""",
    "60"

    "tuple_construction_via_function",
    // Only verifies that ETuple emits without exploding; reading
    // tuple fields needs pattern matching (E6).
    """
package E7
func makePair(a: in Int, b: in Int): (Int, Int) = (a, b)
func main(): Unit {
  val _ = makePair(1, 2)
  println(42)
}
""",
    "42"

    "multi_index_jagged_2d",
    """
package MI1
func main(): Unit {
  val grid = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
  println(grid[0, 0])
  println(grid[1, 2])
  println(grid[2, 1])
}
""",
    "1\n6\n8"

    "multi_index_jagged_3d",
    """
package MI2
func main(): Unit {
  val cube = [[[10, 11], [12, 13]], [[20, 21], [22, 23]]]
  println(cube[0, 0, 0])
  println(cube[0, 1, 1])
  println(cube[1, 0, 1])
  println(cube[1, 1, 0])
}
""",
    "10\n13\n21\n22"

    "tuple_8_elements_compiles",
    """
package T8
func makeOctet(): (Int, Int, Int, Int, Int, Int, Int, Int) =
  (1, 2, 3, 4, 5, 6, 7, 8)
func main(): Unit {
  val _ = makeOctet()
  println(42)
}
""",
    "42"

    "tuple_10_elements_compiles",
    """
package T10
func make10(): (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) =
  (1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
func main(): Unit {
  val _ = make10()
  println(99)
}
""",
    "99"

    "tuple_15_elements_compiles",
    """
package T15
func main(): Unit {
  val _ = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
  println(15)
}
""",
    "15"

    // slice[T] as a function parameter type — verify TypeMap resolves it to T[]
    // and the emitter emits correct Ldelem / ldlen instructions.
    "slice_as_function_param",
    """
package SL1
func sumSlice(xs: in slice[Int]): Int {
  var total = 0
  var i = 0
  while i < xs.length {
    total += xs[i]
    i += 1
  }
  return total
}
func main(): Unit {
  println(sumSlice([1, 2, 3, 4, 5]))
}
""",
    "15"

    // slice[String] function parameter and for-in iteration.
    "slice_string_param_forin",
    """
package SL2
func printAll(xs: in slice[String]): Unit {
  for x in xs { println(x) }
}
func main(): Unit {
  printAll(["hello", "world", "!"])
}
""",
    "hello\nworld\n!"

    // Pure-Lyric join: demonstrates slice indexing with a mutable counter
    // and returning a constructed string.
    "slice_manual_join",
    """
package SL3
func join(separator: in String, parts: in slice[String]): String {
  var result = ""
  var i = 0
  while i < parts.length {
    if i > 0 { result = result + separator }
    result = result + parts[i]
    i += 1
  }
  return result
}
func main(): Unit {
  println(join(", ", ["a", "b", "c"]))
}
""",
    "a, b, c"
]

let tests =
    testSequenced
    <| testList "slices + lists + indexing (E7)"
        (cases |> List.map mk)
