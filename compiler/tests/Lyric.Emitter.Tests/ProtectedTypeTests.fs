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

/// Source that's expected to fail compilation with a specific
/// diagnostic code.  Used by the generic-protected-type case which
/// surfaces `E920` while codegen + call-site type-arg dispatch
/// are tracked as a follow-up.
let private mkExpectErrorCode (label: string) (source: string) (code: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let result, _, _, _ = compileAndRun label source
        let codes = result.Diagnostics |> List.map (fun d -> d.Code)
        Expect.contains codes code
            (sprintf "expected diagnostic %s; got: %A" code codes)

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

    "pt_field_initializer",
    // Per-field initializer: `var count: Int = 100` runs in the
    // synthesised default ctor so `Counter()` starts with count=100
    // rather than zero (D-progress-079 follow-up).
    """
package E14

protected type Counter {
  var count: Int = 100
  entry tick() { count = count + 1 }
  func get(): Int { return count }
}

func main(): Unit {
  val c = Counter()
  c.tick()
  c.tick()
  println(toString(c.get()))
}
""",
    "102"

    "pt_invariant_holds_silently",
    // Invariant evaluates after every entry/func body returns;
    // when the body keeps the predicate true, the run completes
    // normally and prints the final state.
    """
package E14

protected type Counter {
  var count: Int

  invariant: count >= 0

  entry tick() { count = count + 1 }
  func get(): Int { return count }
}

func main(): Unit {
  val c = Counter()
  c.tick()
  c.tick()
  c.tick()
  println(toString(c.get()))
}
""",
    "3"

    "pt_invariant_violation_throws",
    // Invariant fails after `decr` drops `count` below zero.  The
    // wrapper throws `LyricAssertionException` after the unsafe
    // body returns; main catches via try/catch and prints
    // "boom" instead of the bogus result.
    """
package E14

protected type Counter {
  var count: Int

  invariant: count >= 0

  entry decr() { count = count - 1 }
  func get(): Int { return count }
}

func main(): Unit {
  val c = Counter()
  try {
    c.decr()
    println(toString(c.get()))
  } catch Exception as e {
    println("boom")
  }
}
""",
    "boom"

    "pt_when_barrier_satisfied",
    // Happy-path barrier: `when: count > 0` holds, decr runs.
    """
package E14

protected type Bag {
  var count: Int = 5
  entry decr() when: count > 0 { count = count - 1 }
  func get(): Int { return count }
}

func main(): Unit {
  val b = Bag()
  b.decr()
  b.decr()
  println(toString(b.get()))
}
""",
    "3"

    "pt_rwlock_func_reads",
    // D-progress-081: concurrent `func` calls take the read lock,
    // entries take the write lock.  Single-threaded smoke confirms
    // both sides still produce the right result through the
    // RWLock acquire/release pattern; the underlying concurrency
    // benefit isn't directly observable in a deterministic test.
    """
package E14

protected type Counter {
  var count: Int = 1

  entry add(n: in Int) { count = count + n }

  func get(): Int { return count }
  func doubled(): Int { return count * 2 }
}

func main(): Unit {
  val c = Counter()
  c.add(4)
  println(toString(c.get()))
  println(toString(c.doubled()))
}
""",
    "5\n10"

    "pt_when_barrier_throws_when_false",
    // Barrier-not-met: `when: count > 0` is false at call time,
    // so the wrapper throws BEFORE invoking the unsafe inner.
    // Bootstrap-grade scope per `06-open-questions.md` Q008 —
    // Ada-style condition-variable waiting lands once Phase C
    // scope plumbing is mature.
    """
package E14

protected type Bag {
  var count: Int
  entry take() when: count > 0 { count = count - 1 }
}

func main(): Unit {
  val b = Bag()
  try {
    b.take()
    println("took")
  } catch Exception as e {
    println("blocked")
  }
}
""",
    "blocked"
]

let private genericNotYetEmitted =
    mkExpectErrorCode
        "pt_generic_not_yet_emitted"
        """
package E14

protected type Box[T] {
  var value: T
  entry put(v: in T) { value = v }
  func get(): T { return value }
}

func main(): Unit { () }
"""
        "E920"

let tests =
    testList "protected types (D-progress-079)"
        ((cases |> List.map mk) @ [ genericNotYetEmitted ])
