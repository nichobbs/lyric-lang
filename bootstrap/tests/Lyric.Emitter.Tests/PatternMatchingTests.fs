module Lyric.Emitter.Tests.PatternMatchingTests

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

    // ── Tuple destructuring ──────────────────────────────────────────────

    "tuple_two_ints",
    """
package E20
func main(): Unit {
  val t = (10, 20)
  match t {
    case (a, b) -> println(a + b)
  }
}
""",
    "30"

    "tuple_wildcard_second",
    """
package E20
func main(): Unit {
  val t = (42, 99)
  match t {
    case (x, _) -> println(x)
  }
}
""",
    "42"

    "tuple_three_elements",
    """
package E20
func main(): Unit {
  val t = (1, 2, 3)
  match t {
    case (a, b, c) -> println(a + b + c)
  }
}
""",
    "6"

    "tuple_nested_in_function",
    """
package E20
func swap(p: in (Int, Int)): (Int, Int) {
  match p {
    case (a, b) -> (b, a)
  }
}
func main(): Unit {
  val (x, y) = swap((7, 3))
  println(x)
  println(y)
}
""",
    "3\n7"

    "tuple_all_wildcards",
    """
package E20
func main(): Unit {
  val t = (1, 2)
  match t {
    case (_, _) -> println("matched")
  }
}
""",
    "matched"

    // ── Or-patterns ──────────────────────────────────────────────────────

    "or_nullary_union_cases",
    """
package E20
union Dir { case North, case South, case East, case West }
func isVertical(d: in Dir): Bool {
  match d {
    case North | South -> true
    case East  | West  -> false
  }
}
func main(): Unit {
  println(isVertical(North))
  println(isVertical(South))
  println(isVertical(East))
  println(isVertical(West))
}
""",
    "True\nTrue\nFalse\nFalse"

    "or_literal_int",
    """
package E20
func classify(n: in Int): String {
  match n {
    case 0 | 1 -> "tiny"
    case 2 | 3 -> "small"
    case _     -> "large"
  }
}
func main(): Unit {
  println(classify(0))
  println(classify(1))
  println(classify(3))
  println(classify(9))
}
""",
    "tiny\ntiny\nsmall\nlarge"

    "or_three_alternatives",
    """
package E20
union Color { case Red, case Green, case Blue, case Other }
func isPrimary(c: in Color): Bool {
  match c {
    case Red | Green | Blue -> true
    case _                  -> false
  }
}
func main(): Unit {
  println(isPrimary(Red))
  println(isPrimary(Other))
}
""",
    "True\nFalse"

    "or_pattern_with_shared_binding",
    """
package E20
union Shape { case Circle(r: Int), case Square(r: Int) }
func radius(s: in Shape): Int {
  match s {
    case Circle(r) | Square(r) -> r
  }
}
func main(): Unit {
  println(radius(Circle(r = 5)))
  println(radius(Square(r = 3)))
}
""",
    "5\n3"

    // ── Nested constructor patterns ──────────────────────────────────────

    "nested_option_int",
    """
package E20
union Opt { case Some(value: Int), case None }
func unwrap(o: in Opt): Int {
  match o {
    case Some(v) -> v
    case None    -> -1
  }
}
func main(): Unit {
  println(unwrap(Some(value = 42)))
  println(unwrap(None))
}
""",
    "42\n-1"

    "nested_two_levels",
    """
package E20
union Inner { case A(x: Int), case B }
union Outer { case Wrap(inner: Inner), case Empty }
func extract(o: in Outer): Int {
  match o {
    case Wrap(A(x)) -> x
    case Wrap(B)    -> 0
    case Empty      -> -1
  }
}
func main(): Unit {
  println(extract(Wrap(inner = A(x = 7))))
  println(extract(Wrap(inner = B)))
  println(extract(Empty))
}
""",
    "7\n0\n-1"

    "nested_with_wildcard",
    """
package E20
union Box { case Full(value: Int, tag: Int), case Empty }
func getValue(b: in Box): Int {
  match b {
    case Full(v, _) -> v
    case Empty      -> 0
  }
}
func main(): Unit {
  println(getValue(Full(value = 10, tag = 99)))
  println(getValue(Empty))
}
""",
    "10\n0"

    "nested_constructor_in_or",
    """
package E20
union Shape { case Circle(r: Int), case Square(r: Int), case Point }
func size(s: in Shape): Int {
  match s {
    case Circle(r) | Square(r) -> r
    case Point                 -> 0
  }
}
func main(): Unit {
  println(size(Circle(r = 4)))
  println(size(Square(r = 6)))
  println(size(Point))
}
""",
    "4\n6\n0"

]

let tests =
    testSequenced
    <| testList "pattern matching — tuples, or-patterns, nested constructors (E20)"
        (cases |> List.map mk)
