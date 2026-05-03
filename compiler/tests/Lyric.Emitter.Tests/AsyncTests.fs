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

    "phaseB_async_generic",
    // D-progress-047: async generic function calls now return
    // their wrapped `Task[<T>]` static type at the call site so
    // `await` resolves `GetAwaiter` correctly.  Generic async
    // funcs themselves still go through the M1.4 wrapper path
    // (the SM doesn't yet emit closed-generic SM types on
    // TypeBuilder); the fix is purely on the call-site type
    // surfacing.
    """
package E14
async func id[T](x: in T): T = x
func main(): Unit {
  println(await id(42))
  println(await id("hi"))
}
""",
    "42\nhi"

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

    "phaseBPlusPlusPlus_try_await_no_throw",
    // Phase B+++ (D-progress-056): trailing `await` inside a `try`
    // body lowers to the duplicated-post-await pattern.  Awaitable
    // doesn't throw; the GetResult value is bound to `r` and
    // discarded as the try exits via Leave.  Catches must not be
    // entered.
    """
package E14
async func sayHi(): Unit { println("hi from try") }
async func runner(): Unit {
  try {
    await sayHi()
  } catch Exception as e {
    println("oops")
  }
  println("after")
}
func main(): Unit {
  await runner()
}
""",
    "hi from try\nafter"

    "phaseBPlusPlusPlus_try_await_pre_stmts",
    // Pre-stmts in the try body run on the first-time path only;
    // resume re-enters a duplicated try whose body is just
    // GetResult.  This test exercises a Task-completes-synchronously
    // path so resume is never taken — but the IL is still emitted
    // and must verify.
    """
package E14
async func answer(): Int = 42
async func runner(): Unit {
  try {
    println("before")
    val r = await answer()
    val ignored = r
  } catch Exception as e {
    println("err")
  }
  println("done")
}
func main(): Unit {
  await runner()
}
""",
    "before\ndone"

    "phaseBPlusPlusPlus_try_await_caught",
    // Awaitable throws via panic propagated through Task; the
    // user `catch` traps it.  Validates that GetResult's exception
    // is caught by the surrounding user catch handler in the
    // first-time path.
    """
package E14
async func bomb(): Int { panic("boom") ; return 0 }
async func runner(): Unit {
  try {
    val r = await bomb()
    val ignored = r
  } catch Exception as e {
    println("caught")
  }
  println("after")
}
func main(): Unit {
  await runner()
}
""",
    "caught\nafter"

    "phaseBPlusPlusPlus_defer_await_no_throw",
    // Phase B+++ (D-progress-057): `defer { cleanup }; await foo()`
    // — cleanup is registered on entry, await suspends, cleanup
    // runs once on scope exit (normal completion).  Must NOT
    // double-run cleanup at the suspend point.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func runner(): Unit {
  defer { println("cleanup") }
  println("before-await")
  await Task.Delay(10)
}
func main(): Unit {
  await runner()
  println("after")
}
""",
    "before-await\ncleanup\nafter"

    "phaseBPlusPlusPlus_defer_await_pre_defer_stmt",
    // Pre-defer stmts run unconditionally; defer registers; between-
    // defer-and-await stmts are inside the protected region; await
    // suspends; cleanup runs at scope exit.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func runner(): Unit {
  println("pre-defer")
  defer { println("cleanup") }
  println("between")
  await Task.Delay(5)
}
func main(): Unit {
  await runner()
  println("done")
}
""",
    "pre-defer\nbetween\ncleanup\ndone"

    "phaseBPlusPlusPlus_for_await_basic",
    // Phase B+++ (D-progress-058): `await` inside a `for x in ...`
    // body.  The iterator slice, the loop index, and the loop
    // variable `x` are field-backed on the SM so their values
    // survive the cross-resume gap.  Real Task.Delay forces real
    // suspension on each iteration.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func runner(): Unit {
  val items: slice[Int] = [10, 20, 30]
  for n in items {
    await Task.Delay(2)
    println(toString(n))
  }
}
func main(): Unit {
  await runner()
  println("done")
}
""",
    "10\n20\n30\ndone"

    "stack_spill_await_in_call_arg",
    // D-progress-074: `f(await g())` — a previously-M1.4 shape lifts
    // to Phase B via the AST-rewrite spilling pass.  The rewrite
    // hoists `await g()` to a preceding `val __spill_0 = await g()`
    // binding and replaces the call arg with the spill local.  The
    // existing Phase B safe-position emit then runs unchanged.
    """
package E14
async func produce(): Int = 21
async func runner(): Unit {
  println(toString(await produce() + 1))
}
func main(): Unit {
  await runner()
}
""",
    "22"

    "stack_spill_two_await_args",
    // Two awaits in a single call: each gets spilled to its own
    // synthesised local.  The spill-local for the first await must
    // survive across the second await's suspend (when running with a
    // real Task), so it's promoted to an SM field.  Here both inner
    // calls return synchronously so the suspend path is the fast
    // already-completed branch.
    """
package E14
async func a(): Int = 5
async func b(): Int = 7
async func runner(): Unit {
  println(toString(await a() + await b()))
}
func main(): Unit {
  await runner()
}
""",
    "12"

    "stack_spill_await_in_binop",
    // `n + await foo()` — the await sits in the right operand of a
    // binary op.  Spilled to `val __spill_0 = await foo()`, the binop
    // becomes `n + __spill_0`.
    """
package E14
async func foo(): Int = 30
async func runner(n: in Int): Unit {
  val total: Int = n + await foo()
  println(toString(total))
}
func main(): Unit {
  await runner(12)
}
""",
    "42"

    "stack_spill_real_suspend_through_call_arg",
    // Real BCL Task.Delay-based suspend going through the spilled
    // path: `await Task.Delay(10)` returns a Task[Unit] whose result
    // is `()`.  We use a value-returning real-async pattern instead
    // (an inline async helper that delegates) to exercise the
    // spilled call-arg + non-pre-completed task combination.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func slow(): Int {
  await Task.Delay(10)
  return 99
}
async func runner(): Unit {
  println(toString(await slow() + 1))
}
func main(): Unit {
  await runner()
}
""",
    "100"

    "phaseBPlusPlusPlus_try_await_real_suspend",
    // Real BCL Task.Delay forces the suspend/resume path: the
    // Task is NOT pre-completed at the IsCompleted check, so the
    // first-time .try Leaves to the outer end, the SM is parked,
    // the timer fires, MoveNext re-enters, dispatch jumps to the
    // resume label between the two .try copies, and the second
    // .try drains GetResult.  Catches must not be entered.
    """
package E14
extern type Task = "System.Threading.Tasks.Task"
async func runner(): Unit {
  try {
    println("before-delay")
    await Task.Delay(10)
  } catch Exception as e {
    println("err")
  }
  println("after-try")
}
func main(): Unit {
  await runner()
}
""",
    "before-delay\nafter-try"

    "phaseB_generic_async_phaseA",
    // D-progress-075: generic async funcs now lower to a real
    // generic IAsyncStateMachine instead of the M1.4 Task.FromResult
    // shim.  This case exercises Phase A (await-free body) on a
    // single-type-param generic.
    """
package E14
async func id[T](x: in T): T = x
func main(): Unit {
  println(await id(42))
  println(await id("hi"))
}
""",
    "42\nhi"

    "phaseB_generic_async_phaseB_with_await",
    // Phase B + generics: an async generic body that contains an
    // `await`.  The SM is a generic class; the kickoff (inside
    // the user's generic method) closes the SM via `MakeGenericType`
    // over the user method's GTPB and routes Newobj / Stfld via
    // `TypeBuilder.GetConstructor` / `TypeBuilder.GetField`.
    """
package E14
async func produce(): Int = 99
async func wrap[T](x: in T): T {
  val _: Int = await produce()
  return x
}
func main(): Unit {
  println(toString(await wrap(7)))
}
""",
    "7"

    "stack_spill_preserves_left_to_right_order",
    // D-progress-076 follow-up: when a side-effecting sibling sits
    // to the left of an awaited expression in the same statement,
    // the spill rewrite hoists that sibling FIRST so its observable
    // effects fire before the await suspends.  Without the prior-
    // sibling spill, the rewrite would reorder
    // `add(sideEffect(), await produce())` into
    // `val s = await produce(); add(sideEffect(), s)` — flipping
    // the print order.  The fix hoists `sideEffect()` to a `__tmp_*`
    // before the await spill so the original left-to-right order is
    // preserved.
    """
package E14
async func produce(): Int = 5
func sideEffect(): Int {
  println("called")
  return 10
}
func add(a: in Int, b: in Int): Int = a + b
async func runner(): Int {
  return add(sideEffect(), await produce())
}
func main(): Unit {
  println(toString(await runner()))
}
""",
    "called\n15"

    "phaseB_generic_async_two_type_params",
    // Generic async with two type parameters — confirms
    // `MakeGenericType` over multiple arg slots and that
    // SM-side fields close correctly across all of them.
    """
package E14
async func zip[A, B](a: in A, b: in B): A {
  return a
}
func main(): Unit {
  println(toString(await zip(123, "ignored")))
}
""",
    "123"
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

/// D-progress-074: stack-spilling rewrite synthesises
/// `__spill_<n>` SM-promoted locals when an async body has awaits in
/// non-safe sub-expression positions.  This guard test reflects on
/// the emitted assembly to confirm those fields exist on the SM
/// type, catching regressions where the rewrite stops firing.
let private stackSpillSmShape : Test =
    testCase "[stack_spill_sm_shape] spill fields appear on SM" <| fun () ->
        let label = "AsyncSpillShape"
        let source = """
package E14
async func produce(): Int = 21
async func runner(): Unit {
  println(toString(await produce() + 1))
}
func main(): Unit {
  await runner()
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
        let runnerSm =
            smTypes
            |> Array.tryFind (fun t -> t.Name.Contains "runner")
        match runnerSm with
        | None ->
            failwith "expected an SM type for `runner`"
        | Some sm ->
            // Promoted locals follow the `<l>__<name>` convention.
            let spillField = sm.GetField "<l>__<__spill_0>"
            let candidate =
                if spillField <> null then spillField
                else sm.GetField "<l>____spill_0"
            Expect.isNotNull candidate
                "rewrite should promote __spill_0 to an SM field"

/// D-progress-075: generic async funcs lower to a generic SM
/// class.  This guard test reflects on the emitted assembly to
/// confirm the SM type carries one generic parameter for a single-
/// type-param async func, catching regressions where the routing
/// flag flips back to the M1.4 wrapper.
let private genericSmShape : Test =
    testCase "[generic_sm_shape] generic async emits generic SM" <| fun () ->
        let label = "AsyncGenericSmShape"
        let source = """
package E14
async func id[T](x: in T): T = x
func main(): Unit {
  println(toString(await id(42)))
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
        let idSm =
            smTypes |> Array.tryFind (fun t -> t.Name.Contains "id")
        match idSm with
        | None -> failwith "expected an SM type for `id`"
        | Some sm ->
            Expect.isTrue sm.IsGenericTypeDefinition
                "id's SM should be a generic type definition"
            Expect.equal (sm.GetGenericArguments().Length) 1
                "id's SM should have one generic parameter"

let tests =
    testList "async tests" [
        behavioral
        smShape
        stackSpillSmShape
        genericSmShape
    ]
