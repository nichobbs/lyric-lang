module Lyric.Emitter.Tests.AsyncTests

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

/// Per D-progress-024 (C2 Phase A), `async func` whose body contains
/// no internal `await` lowers to a real `IAsyncStateMachine` class
/// with `<>1__state` / `<>t__builder` fields, a `MoveNext` carrying
/// the user body, and a kickoff stub that calls
/// `AsyncTaskMethodBuilder<T>.Start` and returns `builder.Task`.
/// `await` at call sites still uses the M1.4 `GetAwaiter().GetResult()`
/// shim — these test cases all run synchronously through the SM and
/// the awaited Task is already-completed when the caller reaches
/// `GetAwaiter().GetResult()`.
let private cases : (string * string * string) list = [

    "await_int",
    """
package E14
async func twice(n: in Int): Int = n + n
func main(): Unit {
  println(await twice(21))
}
""",
    "42"

    "await_string",
    // Phase 1's binary `+` doesn't yet handle string concatenation
    // (the codegen emits an arithmetic add); the async return path
    // is what's being verified here.
    """
package E14
async func passthrough(name: in String): String = name
func main(): Unit {
  println(await passthrough("alice"))
}
""",
    "alice"

    "two_async_calls",
    """
package E14
async func add(a: in Int, b: in Int): Int = a + b
func main(): Unit {
  val x = await add(1, 2)
  val y = await add(x, 10)
  println(y)
}
""",
    "13"

    "async_void",
    """
package E14
async func sayHi(): Unit { println("hi from async") }
func main(): Unit {
  await sayHi()
}
""",
    "hi from async"

    "async_block_with_locals",
    // Block body with local bindings + arithmetic — exercises the
    // exit-label / result-local path through the SM.
    """
package E14
async func compute(a: in Int, b: in Int): Int {
  val x = a * 2
  val y = b * 3
  x + y
}
func main(): Unit {
  println(await compute(4, 5))
}
""",
    "23"

    "phaseB_await_inner_async_void",
    // Phase B: async func body contains an `await` of another
    // Lyric async function.  The inner is Phase A (sync body), so
    // `inner().GetAwaiter().IsCompleted` is true and execution
    // takes the fast path through the suspend/resume protocol —
    // exercises the IL shape (state-dispatch switch, awaiter
    // field, after-await label) without actually suspending.
    """
package E14
async func inner(): Unit { println("inner") }
async func outer(): Unit {
  await inner()
  println("outer")
}
func main(): Unit {
  await outer()
}
""",
    "inner\nouter"

    "phaseB_two_awaits_void",
    // Two await sites → state indices 0 and 1, two resume labels.
    """
package E14
async func ping(): Unit { println("ping") }
async func twoAwaits(): Unit {
  await ping()
  await ping()
}
func main(): Unit {
  await twoAwaits()
}
""",
    "ping\nping"

    "phaseB_await_returns_int",
    // Non-Unit return: `await` of a Task<Int> exercises the
    // generic awaiter path + the result_local SetResult sequence.
    """
package E14
async func mkValue(): Int = 42
async func passes(): Int {
  await mkValue()
}
func main(): Unit {
  println(await passes())
}
""",
    "42"

    "phaseB_real_task_delay_suspends",
    // Real BCL Task.Delay via auto-FFI on `extern type Task`.
    // Task.Delay(ms) returns a Task that's NOT pre-completed when
    // ms > 0, so the suspend/resume path runs end-to-end (state
    // saved, AwaitUnsafeOnCompleted called, MoveNext re-entered
    // when the timer fires).  Validates the IL emits a working
    // suspension protocol — not just the structural shape.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func sleeps(ms: in Int): Unit {
  await Task.Delay(ms)
  println("woke")
}
func main(): Unit {
  await sleeps(10)
}
""",
    "woke"

    "phaseB_promoted_local_across_await",
    // Promoted local `val x` is read after an await — exercises
    // the field-shadow protocol.  Body sequence:
    //   1. Compute x = 21 + 21 (pre-await; stored to IL local +
    //      flushed to SM field at suspend).
    //   2. await ping() — synchronously completed, fast path.
    //   3. Read x (loaded from IL local — value preserved).
    """
package E14
async func ping(): Unit { println("ping") }
async func computeAcrossAwait(): Unit {
  val x: Int = 21 + 21
  await ping()
  println(x)
}
func main(): Unit {
  await computeAcrossAwait()
}
""",
    "ping\n42"

    "phaseB_await_in_if_branch",
    // Phase B+ extension: `await` inside an `if` branch.  The
    // suspend protocol's resume label sits inside the then
    // branch's IL block; state-dispatch jumps directly there
    // when MoveNext is re-entered.  Convergence at end-of-if
    // works because the IL stack is empty at suspend (the
    // awaiter is stashed before suspend) and balanced at the
    // join point (each branch leaves the same number of values
    // on the stack — none here).
    """
package E14
async func ping(): Unit { println("ping") }
async func cond(b: in Bool): Unit {
  if b {
    await ping()
    println("yes")
  } else {
    println("no")
  }
}
func main(): Unit {
  await cond(true)
  await cond(false)
}
""",
    "ping\nyes\nno"

    "phaseB_await_in_match_arm",
    // `await` inside a match arm body (Phase B+).  Each arm
    // body is an independent IL flow; the resume label sits
    // inside the matching arm.
    """
package E14
async func tag(s: in String): Unit { println(s) }
async func dispatch(n: in Int): Unit {
  match n {
    case 1 -> await tag("one")
    case 2 -> await tag("two")
    case _ -> println("other")
  }
}
func main(): Unit {
  await dispatch(1)
  await dispatch(2)
  await dispatch(3)
}
""",
    "one\ntwo\nother"

    "phaseB_match_await_scrutinee",
    // Phase B+ (D-progress-041): `match await foo() { ... }`.
    // The scrutinee evaluates the await (suspend/resume protocol),
    // GetResult pushes the value, EMatch's emit Stloc's it to a
    // temp before pattern matching — IL stack is empty at suspend.
    // This is the canonical pattern in Std.Http and BankingSmoke.
    """
package E14
async func get(): Int = 42
async func dispatch(): String {
  match await get() {
    case 42 -> "fortytwo"
    case _ -> "other"
  }
}
func main(): Unit {
  println(await dispatch())
}
""",
    "fortytwo"

    "phaseB_if_await_cond",
    // Phase B+ (D-progress-041): `if (await cond()) then ... else
    // ...`.  The bool value from the await drives the brfalse /
    // brtrue.
    """
package E14
async func truthy(): Bool = true
async func runner(): Unit {
  if await truthy() {
    println("yes")
  } else {
    println("no")
  }
}
func main(): Unit {
  await runner()
}
""",
    "yes"

    "phaseB_await_returns_user_record",
    // Phase B with a Lyric record as the bare return type — the
    // builder is `AsyncTaskMethodBuilder<UserRecord>` closed over
    // a TypeBuilder still under construction.  Validates that
    // `builderMember` / `Start` / `AwaitUnsafeOnCompleted` /
    // `TaskAwaiter<T>::IsCompleted` lookups all route through
    // `TypeBuilder.GetMethod` correctly (D-progress-040 + 041
    // robustness).
    """
package E14
record Box { value: Int }
async func mkBox(): Box = Box(value = 99)
async func nested(): Box {
  await mkBox()
}
func main(): Unit {
  val b = await nested()
  println(b.value)
}
""",
    "99"

    "phaseB_nested_local_in_while_loop",
    // Phase B++ (D-progress-042): `val y` declared inside a
    // while-loop body, used after the await.  `collectPromotableLocals`
    // walks one level into loop bodies and registers `y` for
    // promotion alongside the top-level `i`.
    """
package E14
async func ping(): Unit { println("ping") }
async func loopWithLocal(): Unit {
  var i: Int = 0
  while i < 2 {
    val y: Int = i + 10
    await ping()
    println(y)
    i = i + 1
  }
}
func main(): Unit {
  await loopWithLocal()
}
""",
    "ping\n10\nping\n11"

    "phaseB_async_impl_method_with_await",
    // Phase B impl method — async instance method whose body
    // contains an `await`.  The kickoff lives on the record;
    // the SM has a `self` field plus an awaiter slot for the
    // suspend/resume protocol.  Validates D-progress-040 (Phase
    // B for impl methods).
    """
package E14
record Counter { v: Int }
async func inner(): Unit { println("inner") }
interface Tagger { async func tag(): Unit }
impl Tagger for Counter {
  async func tag(): Unit {
    await inner()
    println("after")
  }
}
func main(): Unit {
  await Counter(v = 1).tag()
}
""",
    "inner\nafter"

    "phaseB_async_impl_method",
    // Async impl method (Phase A on an instance method).  The
    // kickoff lives on the user's record (instance method), the
    // SM has a `self` field that holds the record reference,
    // `ESelf` resolves via `SmFields["self"]` → `Ldarg.0; Ldfld
    // <self>` inside MoveNext.  Validates the impl-method route
    // through the SM path (D-progress-038).
    """
package E14
record IntCounter { v: Int }
interface ValueGetter { async func getValue(): Int }
impl ValueGetter for IntCounter {
  async func getValue(): Int = self.v + 1
}
func main(): Unit {
  println(await IntCounter(v = 41).getValue())
}
""",
    "42"

    "phaseB_await_in_while_loop",
    // Phase B+: `await` inside a `while` body.  The resume
    // label sits inside the loop body; state-dispatch jumps
    // there on re-entry, then control falls through to the
    // increment statement and the loop's back-edge branches
    // to re-check the condition.  Top-level `var i: Int`
    // gets promoted to an SM field so its value survives
    // the cross-resume gap.
    """
package E14
async func ping(): Unit { println("ping") }
async func loopThree(): Unit {
  var i: Int = 0
  while i < 3 {
    await ping()
    i = i + 1
  }
}
func main(): Unit {
  await loopThree()
}
""",
    "ping\nping\nping"
]

let private behavioral =
    testSequenced
    <| testList "async — Phase A state-machine (E14 / D-progress-024)"
        (cases |> List.map mk)

/// Inspect the emitted assembly to confirm the Phase A SM class was
/// actually synthesised: a sibling top-level type named
/// `<funcname>__SM_<n>` implementing `IAsyncStateMachine`.  Catches
/// regressions where the routing flag flips back to the M1.4
/// `Task.FromResult` shim without anyone noticing.
let private smShape : Test =
    testCase "[sm_shape] async func emits IAsyncStateMachine class" <| fun () ->
        let label = "AsyncSmShape"
        let source = """
package E14
async func twice(n: in Int): Int = n + n
func main(): Unit {
  println(await twice(21))
}
"""
        let outDir = prepareOutputDir label
        let dll    = Path.Combine(outDir, label + ".dll")
        let req : Lyric.Emitter.Emitter.EmitRequest =
            { Source       = source
              AssemblyName = label
              OutputPath   = dll }
        let _ = Lyric.Emitter.Emitter.emit req
        let asm = Assembly.LoadFrom dll
        let smTypes =
            asm.GetTypes()
            |> Array.filter (fun t ->
                typeof<System.Runtime.CompilerServices.IAsyncStateMachine>.IsAssignableFrom(t))
        Expect.isGreaterThanOrEqual smTypes.Length 1
            "expected at least one IAsyncStateMachine implementation"
        let sm = smTypes.[0]
        let stateField = sm.GetField "<>1__state"
        let builderField = sm.GetField "<>t__builder"
        Expect.isNotNull stateField "state field present"
        Expect.isNotNull builderField "builder field present"
        let nField = sm.GetField "n"
        Expect.isNotNull nField "param field 'n' present"

let tests =
    testList "async tests" [
        behavioral
        smShape
    ]
