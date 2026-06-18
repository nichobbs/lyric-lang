/// Tests for D037: methods declared inside a `record` body, hoisted
/// at parse time to top-level UFCS-style `<RecordName>.<methodName>`
/// functions.  The receiver is explicit (`self: in <RecordName>`) in
/// v1; implicit-self injection is a follow-up.
module Lyric.Emitter.Tests.InlineMethodTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "inline_method_basic",
    """
package IM1

record Point {
  x: Int
  y: Int

  func sum(self: in Point): Int = self.x + self.y
}

func main(): Unit {
  val p = Point(x = 3, y = 4)
  println(p.sum())
}
""",
    "7"

    "inline_method_with_args",
    """
package IM2

record Point {
  x: Int
  y: Int

  func translate(self: in Point, dx: in Int, dy: in Int): Point =
    Point(x = self.x + dx, y = self.y + dy)
}

func main(): Unit {
  val p = Point(x = 1, y = 2)
  val q = p.translate(10, 20)
  println(q.x)
  println(q.y)
}
""",
    "11\n22"

    "inline_method_chained",
    """
package IM3

record Counter {
  n: Int

  func bump(self: in Counter): Counter = Counter(n = self.n + 1)
  func value(self: in Counter): Int    = self.n
}

func main(): Unit {
  val c = Counter(n = 0)
  println(c.bump().bump().bump().value())
}
""",
    "3"

    "inline_method_alongside_top_level_ufcs",
    """
package IM4

record Box {
  v: Int

  func get(self: in Box): Int = self.v
}

// Same UFCS form declared at top level — both work side by side.
func Box.doubled(self: in Box): Int = self.v * 2

func main(): Unit {
  val b = Box(v = 5)
  println(b.get())
  println(b.doubled())
}
""",
    "5\n10"

    "exposed_record_inline_method",
    """
package IM5

exposed record Pair {
  a: Int
  b: Int

  func diff(self: in Pair): Int = self.a - self.b
}

func main(): Unit {
  val p = Pair(a = 10, b = 3)
  println(p.diff())
}
""",
    "7"
]

let tests =
    testSequenced
    <| testList "inline methods (D037)" (cases |> List.map mk)
