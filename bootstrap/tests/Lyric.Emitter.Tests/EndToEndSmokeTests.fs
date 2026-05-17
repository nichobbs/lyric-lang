/// E10 — end-to-end smoke. A curated set of substantial Lyric
/// programs that exercise every M1.3 feature in concert (locals,
/// arithmetic, control flow, functions, records, enums, match,
/// arrays). Each program compiles, runs under `dotnet exec`, and
/// produces a deterministic stdout we can assert on.
///
/// The original plan called for picking the subset out of
/// `docs/02-worked-examples.md`, but most of the doc examples
/// depend on features deferred to M1.4 (contracts, generics,
/// opaque types, wire blocks, async, FFI). A handful of curated
/// programs that fit the M1.3 surface gives a higher-signal smoke
/// test than filtering 22 examples.
module Lyric.Emitter.Tests.EndToEndSmokeTests

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

    "fibonacci",
    """
package E10
func fib(n: in Int): Int {
  if n <= 1 then n else fib(n - 1) + fib(n - 2)
}
func main(): Unit {
  var i = 0
  while i < 10 {
    println(fib(i))
    i += 1
  }
}
""",
    "0\n1\n1\n2\n3\n5\n8\n13\n21\n34"

    "records_2d_distance",
    // Manhattan distance between two points using records and a
    // helper function.
    """
package E10
record Point { x: Int, y: Int }
func absDiff(a: in Int, b: in Int): Int {
  if a > b then a - b else b - a
}
func manhattan(p: in Point, q: in Point): Int {
  return absDiff(p.x, q.x) + absDiff(p.y, q.y)
}
func main(): Unit {
  val a = Point(x = 1, y = 2)
  val b = Point(x = 4, y = 6)
  println(manhattan(a, b))
}
""",
    "7"

    "enum_state_machine",
    // Tiny traffic-light cycler. Three steps; each `next` returns
    // the next colour.
    """
package E10
enum Light { case Red, case Yellow, case Green }
func next(l: in Light): Light {
  match l {
    case Red    -> Light.Green
    case Green  -> Light.Yellow
    case Yellow -> Light.Red
  }
}
func name(l: in Light): String {
  match l {
    case Red    -> "stop"
    case Yellow -> "slow"
    case Green  -> "go"
  }
}
func main(): Unit {
  var l = Light.Red
  var i = 0
  while i < 4 {
    println(name(l))
    l = next(l)
    i += 1
  }
}
""",
    "stop\ngo\nslow\nstop"

    "array_sum_and_product",
    """
package E10
func sumOf(xs: in slice[Int]): Int {
  var s = 0
  for x in xs { s += x }
  return s
}
func productOf(xs: in slice[Int]): Int {
  var p = 1
  for x in xs { p *= x }
  return p
}
func main(): Unit {
  val xs = [1, 2, 3, 4, 5]
  println(sumOf(xs))
  println(productOf(xs))
  println(xs.length)
}
""",
    "15\n120\n5"

    "record_update_pattern",
    // No first-class `with`; rebuild via the constructor.
    """
package E10
record Counter { value: Int, max: Int }
func tick(c: in Counter): Counter {
  return Counter(value = c.value + 1, max = c.max)
}
func main(): Unit {
  var c = Counter(value = 0, max = 5)
  while c.value < c.max {
    c = tick(c)
    println(c.value)
  }
}
""",
    "1\n2\n3\n4\n5"

    "match_int_categorise",
    """
package E10
func categorise(n: in Int): String {
  match n {
    case 0 -> "zero"
    case 1 -> "one"
    case 2 -> "two"
    case _ -> if n < 0 then "negative" else "many"
  }
}
func main(): Unit {
  println(categorise(0))
  println(categorise(1))
  println(categorise(2))
  println(categorise(99))
  println(categorise(-3))
}
""",
    "zero\none\ntwo\nmany\nnegative"

    "fizzbuzz",
    """
package E10
func describe(n: in Int): String {
  if n % 15 == 0 then "FizzBuzz"
  else if n % 3 == 0 then "Fizz"
  else if n % 5 == 0 then "Buzz"
  else "."
}
func main(): Unit {
  var i = 1
  while i <= 15 {
    println(describe(i))
    i += 1
  }
}
""",
    ".\n.\nFizz\n.\nBuzz\nFizz\n.\n.\nFizz\nBuzz\n.\nFizz\n.\n.\nFizzBuzz"

    "factorial_iterative",
    """
package E10
func factorial(n: in Int): Int {
  var acc = 1
  var i = 2
  while i <= n {
    acc *= i
    i += 1
  }
  return acc
}
func main(): Unit {
  println(factorial(0))
  println(factorial(5))
  println(factorial(10))
}
""",
    "1\n120\n3628800"
]

let tests =
    testSequenced
    <| testList "end-to-end smoke (E10)"
        (cases |> List.map mk)
