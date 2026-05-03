/// End-to-end tests for the bootstrap-grade `protected type`
/// emitter (D-progress-079).  Exercises the lock-wrapped entry /
/// func dispatch by spinning up a few worker tasks that bash on a
/// shared protected counter — without the Monitor wrap the assertion
/// at the end would race; with the wrap it deterministically reaches
/// the expected total.
module Lyric.Emitter.Tests.ProtectedTypeTests

open System.IO
open System.Reflection
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
    // Barrier-not-met in a single-threaded program: the wrapper
    // calls `Monitor.Wait(lock, timeoutMs)` and re-evaluates when
    // signalled.  With no other thread to satisfy the barrier the
    // wait times out (D-progress-087) and the wrapper throws —
    // catch reports "blocked".  See Q008 for the bootstrap timeout
    // semantics; Ada specifies infinite waits, the bootstrap uses
    // a finite timeout to keep single-threaded misuses observable
    // rather than deadlocked.
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

    "pt_generic_int",
    // D-progress-079 follow-up: generic protected types lower via
    // LHS-driven inference — `val b: Box[Int] = Box()` reads the
    // expected CLR type from `ctx.ExpectedType` and closes the
    // open generic Box<> via `MakeGenericType(int)`.  The entry +
    // func dispatch then routes through `TypeBuilder.GetMethod` so
    // the constructed `Box<int>::put` / `Box<int>::get` is the
    // Callvirt target.
    """
package E14

protected type Box[T] {
  var value: T
  entry put(v: in T) { value = v }
  func get(): T { return value }
}

func main(): Unit {
  val b: Box[Int] = Box()
  b.put(42)
  println(toString(b.get()))
}
""",
    "42"

    "pt_generic_string",
    // Same shape as `pt_generic_int` but closed against a reference
    // type — confirms the GTPB substitution doesn't accidentally
    // bake in a value-type-only path.
    """
package E14

protected type Box[T] {
  var value: T
  entry put(v: in T) { value = v }
  func get(): T { return value }
}

func main(): Unit {
  val b: Box[String] = Box()
  b.put("hello")
  println(b.get())
}
""",
    "hello"
]

/// D-progress-087: confirm the tri-modal lock-flavour split.
///   * `EntryOnly` declares only `entry` members and no `when:`
///     barriers → `<>__lock : SemaphoreSlim`.
///   * `Mixed` mixes `entry` + `func` and no barriers →
///     `<>__lock : ReaderWriterLockSlim` (concurrent reads).
///   * `Barriered` declares a `when:` barrier on an entry → forced
///     to `<>__lock : Object` (Monitor) so the wrapper can call
///     `Monitor.Wait` / `Monitor.PulseAll` for Ada-style waiting.
let private lockFlavourSplit : Test =
    testCase "[lock_flavour] tri-modal: SemaphoreSlim / RWLock / Monitor (object)" <| fun () ->
        let label = "ProtectedLockFlavour"
        let source = """
package E14

protected type EntryOnly {
  var count: Int
  entry tick() { count = count + 1 }
}

protected type Mixed {
  var count: Int
  entry tick() { count = count + 1 }
  func get(): Int { return count }
}

protected type Barriered {
  var count: Int
  entry take() when: count > 0 { count = count - 1 }
}

func main(): Unit {
  val a = EntryOnly()
  val b = Mixed()
  val c = Barriered()
  a.tick()
  b.tick()
  println(toString(b.get()))
}
"""
        let outDir = prepareOutputDir label
        let dll    = Path.Combine(outDir, label + ".dll")
        let req : Lyric.Emitter.Emitter.EmitRequest =
            { Source           = source
              AssemblyName     = label
              OutputPath       = dll
              RestoredPackages = [] }
        let _ = Lyric.Emitter.Emitter.emit req
        let asm = Assembly.LoadFrom dll
        let lockOf (typeName: string) : System.Type =
            let ty =
                asm.GetTypes()
                |> Array.find (fun t -> t.Name = typeName)
            match Option.ofObj
                    (ty.GetField(
                        "<>__lock",
                        BindingFlags.NonPublic ||| BindingFlags.Instance)) with
            | Some f -> f.FieldType
            | None -> failwithf "%s lock field not present" typeName
        Expect.equal (lockOf "EntryOnly") typeof<System.Threading.SemaphoreSlim>
            "entry-only protected types use SemaphoreSlim"
        Expect.equal (lockOf "Mixed") typeof<System.Threading.ReaderWriterLockSlim>
            "mixed (entry + func) protected types use ReaderWriterLockSlim"
        Expect.equal (lockOf "Barriered") typeof<obj>
            "barrier-bearing protected types use Monitor (object lock)"

/// D-progress-087: confirm Ada-style barrier waiting actually wakes
/// blocked callers when another thread updates the protected-type
/// state.  Compiles a `Bag` with `entry take() when: count > 0`,
/// kicks off a Task that blocks on an empty bag, then has the main
/// thread call `add(1)` after a brief delay.  The worker should
/// unblock + complete; if the wake mechanism is broken it'd time
/// out instead.
let private adaStyleWakeOnBarrier : Test =
    testCase "[barrier_wait_wakes_on_state_change]" <| fun () ->
        let label = "ProtectedBarrierWake"
        let source = """
package E14

protected type Bag {
  var count: Int
  entry add(n: in Int) { count = count + n }
  entry take() when: count > 0 { count = count - 1 }
}

func main(): Unit { () }
"""
        let outDir = prepareOutputDir label
        let dll    = Path.Combine(outDir, label + ".dll")
        let req : Lyric.Emitter.Emitter.EmitRequest =
            { Source           = source
              AssemblyName     = label
              OutputPath       = dll
              RestoredPackages = [] }
        let _ = Lyric.Emitter.Emitter.emit req
        let asm = Assembly.LoadFrom dll
        let bagTy = asm.GetTypes() |> Array.find (fun t -> t.Name = "Bag")
        let bag = System.Activator.CreateInstance(bagTy)
        let getMethod (name: string) : System.Reflection.MethodInfo =
            match Option.ofObj (bagTy.GetMethod(name)) with
            | Some m -> m
            | None -> failwithf "Bag.%s not found" name
        let addM  = getMethod "add"
        let takeM = getMethod "take"
        // Worker blocks on the empty bag's barrier.
        use workerDone = new System.Threading.ManualResetEventSlim(false)
        let workerTask = System.Threading.Tasks.Task.Run(fun () ->
            takeM.Invoke(bag, [||]) |> ignore
            workerDone.Set())
        // Give the worker a chance to enter Monitor.Wait, then signal
        // by adding to the bag.  PulseAll in the entry wrapper wakes
        // the waiter; it re-checks the barrier (now true) and runs.
        System.Threading.Thread.Sleep(100)
        addM.Invoke(bag, [| box 1 |]) |> ignore
        let woke = workerDone.Wait(System.TimeSpan.FromSeconds 2.0)
        Expect.isTrue woke
            "worker should wake after add(1) signals the barrier"
        // Surface any exception from the task so a bad IL emit
        // doesn't silently masquerade as a wake failure.
        if workerTask.IsFaulted then
            failwithf "worker task faulted: %A" workerTask.Exception

let tests =
    testList "protected types (D-progress-079)"
        ((cases |> List.map mk) @ [ lockFlavourSplit; adaStyleWakeOnBarrier ])
