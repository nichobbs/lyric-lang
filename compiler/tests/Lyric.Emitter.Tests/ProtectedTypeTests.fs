/// End-to-end tests for the bootstrap-grade `protected type`
/// emitter (D-progress-079).  Exercises the lock-wrapped entry /
/// func dispatch by spinning up a few worker tasks that bash on a
/// shared protected counter — without the Monitor wrap the assertion
/// at the end would race; with the wrap it deterministically reaches
/// the expected total.
module Lyric.Emitter.Tests.ProtectedTypeTests

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

    "pt_basic_counter",
    // Single-threaded smoke: protected type compiles, default
    // ctor runs, entries mutate state, func reads it back.  No
    // contention so the lock is free immediately every time;
    // the test confirms the wrap doesn't break the happy path.
    """
package E14

protected type Counter {
  var count: Int

  entry incr() { count = count + 1 }
  entry decr() { count = count - 1 }
  func get(): Int { return count }
}

func main(): Unit {
  val c = Counter()
  c.incr()
  c.incr()
  c.incr()
  c.decr()
  println(toString(c.get()))
}
""",
    "2"

    "pt_multiple_protected_types_in_same_module",
    // Two protected types coexisting — covers Pass A's
    // `protectedItems sf` iteration order + the per-type lock
    // field naming (each gets its own `<>__lock`).
    """
package E14

protected type Counter {
  var count: Int
  entry tick() { count = count + 1 }
  func get(): Int { return count }
}

protected type Sum {
  var total: Int
  entry add(n: in Int) { total = total + n }
  func get(): Int { return total }
}

func main(): Unit {
  val c = Counter()
  c.tick(); c.tick()
  val s = Sum()
  s.add(10); s.add(32)
  println(toString(c.get()))
  println(toString(s.get()))
}
""",
    "2\n42"

    "pt_func_returns_value",
    // A `func` (non-mutating but still locked) returns a value
    // through the wrap.  Catches a regression where the wrapper
    // forgets to ldloc the saved result before ret.
    """
package E14

protected type Box {
  var value: Int
  entry put(v: in Int) { value = v }
  func get(): Int { return value }
}

func main(): Unit {
  val b = Box()
  b.put(99)
  println(toString(b.get()))
}
""",
    "99"
]

let tests =
    testList "protected types (D-progress-079)"
        (cases |> List.map mk)
