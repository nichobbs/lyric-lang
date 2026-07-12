//! async_spawn_self_test.l — first executable regression test for the
//! *structured-concurrency keywords* `scope { }` / `spawn e` / `await t`
//! (D119 slice S4 / D120).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: the
//! keywords have a self-hosted-only runtime lowering.  On `--target jvm`
//! (D120) `scope { }` opens a virtual-thread `ExecutorService`, `spawn e`
//! submits a synthesized `Callable` capturing `e`'s free variables and
//! yields a `Future`, and `await t` joins it via `Future.get()`.  On
//! `--target dotnet` the keywords still lower to the degenerate synchronous
//! form (MSIL real structured concurrency is D119 S5/S6, not yet shipped) —
//! `spawn e` runs `e` inline and `await` is the identity.  Both models
//! evaluate the same pure functions, so every assertion below holds on both
//! targets: the JVM path proves the real concurrent submit/join produces the
//! same values the synchronous model does.
//!
//! Run in CI via native `lyric test` on both targets:
//!
//!   lyric test lyric-compiler/lyric/async_spawn_self_test.l                 # MSIL
//!   lyric test --target jvm lyric-compiler/lyric/async_spawn_self_test.l    # JVM
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it in-process (MSIL via `Msil.Bridge`, JVM via `Jvm.Bridge`
//! `compileToJarBundled`), then executes it and asserts every embedded
//! assertion held.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1`.
//!
//! The concurrency lives in `async func` helpers (the type checker treats
//! `spawn`/`await` transparently — the value type flows straight through — so
//! a plain `test` block can call an async helper and read its result
//! directly).  Coverage:
//!   - two `spawn`s in a `scope`, awaited and combined via early `return`
//!     inside the scope (exercises the executor-close-on-return path);
//!   - the same via fall-off out of the scope (executor-close-on-fall-off);
//!   - a bare `spawn` with no enclosing `scope` (the degenerate path — the
//!     handle is consumed by `await` with no executor);
//!   - three concurrent spawns to confirm submit/join scales past two;
//!   - a `Unit`-returning spawned task (the boxed-null Callable return);
//!   - `await` in compound positions inside a scope body — compound-assignment
//!     RHS, call arguments, `if` conditions — with trailing statements
//!     asserted (#5569 item 2's reported shape);
//!   - the #5606 operand-stack family (second-argument and both-argument
//!     spawn joins, constructor/method-call arguments, nested awaits,
//!     interpolation segments, list elements, index expressions, `while`
//!     conditions), which the `Lyric.AwaitHoist` middle-end pass rewrites
//!     into hoisted `val` bindings on every target;
//!   - a scope body that panics while a spawned task is still running: the
//!     Throwable propagates instead of hanging in the executor close
//!     (#5569 item 3).
@test_module
package Lyric.AsyncSpawnSelfTest

import Std.Collections
import Std.Core
import Std.Testing
import Std.Time

// A pure leaf the spawned tasks evaluate.  Kept trivial and deterministic so
// the assertions are identical under synchronous and concurrent execution.
async func doubleIt(x: in Int): Int {
  return x * 2
}

async func addOne(x: in Int): Int {
  return x + 1
}

// Two spawns in a scope, awaited and summed via an early `return` *inside* the
// scope — the headline `docs/agent/di-and-async.l` `loadParallel` shape.  The
// executor must close on the return path (a spawned-task join), which the
// synthesized close-`defer` drives.
async func sumDoublesReturn(a: in Int, b: in Int): Int {
  scope {
    val ta = spawn doubleIt(a)
    val tb = spawn doubleIt(b)
    return await ta + await tb
  }
}

// Same two-spawn join, but the scope falls off (result written to an outer var)
// rather than returning from inside — exercises the executor-close-on-fall-off
// path instead of the early-return replay.
async func sumDoublesFallOff(a: in Int, b: in Int): Int {
  var result = 0
  scope {
    val ta = spawn doubleIt(a)
    val tb = spawn doubleIt(b)
    result = await ta + await tb
  }
  return result
}

// A bare `spawn` with no enclosing `scope`: there is no executor, so `spawn`
// stays degenerate (runs synchronously) and the handle flows straight to
// `await`.  Confirms the no-scope path still produces the value.
async func bareSpawnRoundTrip(x: in Int): Int {
  val t = spawn doubleIt(x)
  return await t
}

// Three concurrent spawns combined — confirms submit/join scales past two and
// that distinct capturing `Callable`s coexist in one scope.
async func sumThree(a: in Int, b: in Int, c: in Int): Int {
  scope {
    val ta = spawn doubleIt(a)
    val tb = spawn addOne(b)
    val tc = spawn doubleIt(c)
    return await ta + await tb + await tc
  }
}

// Parenthesised spawn initialisers `val t = (spawn f(x))`: the result-type
// recording must peel the `EParen` (#5194) or `await` would not unbox the
// primitives and the sum would hit the both-`Object` arithmetic gap (#2862).
async func parenSpawnSum(a: in Int, b: in Int): Int {
  scope {
    val ta = (spawn doubleIt(a))
    val tb = (spawn doubleIt(b))
    return await ta + await tb
  }
}

// A `Unit`-returning spawned task: the synthesized `Callable` returns a boxed
// null, which `await` discards.  The side effect (writing an outer var) is the
// observable.  Confirms the void-return Callable path verifies and joins.
async func spawnUnitTask(x: in Int): Int {
  var seen = 0
  scope {
    val t = spawn recordInto(x)
    await t
    seen = x * 3
  }
  return seen
}

async func recordInto(x: in Int): Unit {
  // A pure no-op body: the point is that a Unit-returning spawn compiles,
  // submits, and joins without leaving a stray value on the stack.
  val ignored = x + 0
}

// The same spawn-binding name reused across two sibling `scope { }` blocks.
// Each binding records its result type under the same key, so the codegen's
// `spawnResultTypes` map must overwrite rather than re-insert — `Map.add` is a
// `Dictionary.Add` that throws on a duplicate key (#5185).  Before the guard
// this crashed the compiler; the runtime value confirms both joins still work.
async func reusedBindingName(a: in Int, b: in Int): Int {
  var total = 0
  scope {
    val t = spawn doubleIt(a)
    total = await t
  }
  scope {
    val t = spawn doubleIt(b)
    total = total + await t
  }
  return total
}

// A `var` spawn handle reassigned to a second spawn and awaited again (#5205):
// the `SAssign` reassignment must refresh the slot's `spawnResultTypes` entry the
// same way the original `SLocal` binding did, so the second `await` unboxes the
// joined `Object` correctly.  Both spawns return `Int` (a `var`'s type is fixed),
// and the first handle is awaited before the reassignment so no task leaks.
async func reassignedSpawnHandle(a: in Int, b: in Int): Int {
  scope {
    var handle = spawn doubleIt(a)
    val first = await handle
    handle = spawn addOne(b)
    val second = await handle
    return first + second
  }
}

// Nested `scope { scope { } }` (#5215): a `spawn` in the inner scope submits to
// the innermost executor (`scopeExecSlots.last`) while the outer `spawn` used the
// outer executor, exercising the `scopeExecSlots` stack push (on inner-scope
// entry) and pop (on inner-scope exit).  Both awaited results combine.
async func nestedScopeSpawns(a: in Int, b: in Int): Int {
  scope {
    val ta = spawn doubleIt(a)
    var inner = 0
    scope {
      val tb = spawn addOne(b)
      inner = await tb
    }
    return await ta + inner
  }
}

// A reference-typed (non-`Int`) spawn result: `await` checkcasts the joined
// `Object` back to `String` rather than unboxing a primitive, exercising the
// other arm of `coerceAwaitResult`.
async func greet(name: in String): String {
  return "hi-" + name
}

async func spawnStringResult(name: in String): String {
  scope {
    val t = spawn greet(name)
    return await t
  }
}

// A compound assignment whose RHS contains `await` inside a `scope { }` body,
// followed by further statements (#5569 item 2's reported shape: `x = x +
// await f()` was observed skipping the rest of the body and hanging in the
// executor close).  Covers both await forms in compound-RHS position — a
// spawn-handle join (`await t`, the `Future.get()` path) and a direct async
// call (`await addOne(b)`, the pass-through/Task-unwrap path) — and asserts
// the trailing statement's effect so a silent skip fails the value check.
async func compoundAwaitAssign(a: in Int, b: in Int): Int {
  var x = 1
  var after = 0
  scope {
    val t = spawn doubleIt(a)
    x = x + await t
    x = x + await addOne(b)
    after = 7
  }
  return x * 1000 + after
}

// `await` in a call-argument position inside a `scope { }` body (#5569 item 2
// family): each spawn-handle join happens directly in an argument list, and a
// statement after the calls is asserted.
func combineTwo(a: in Int, b: in Int): Int {
  a * 10 + b
}

async func awaitInCallArg(a: in Int, b: in Int): Int {
  var combined = 0
  var after = 0
  scope {
    val ta = spawn doubleIt(a)
    val tb = spawn addOne(b)
    combined = combineTwo(await ta, 5)
    val second = combineTwo(await tb, 6)
    combined = combined + second
    after = 3
  }
  return combined * 10 + after
}

// ── #5606: operand-stack values live across an await ─────────────────────────
// Before the statement-level await hoist (`Lyric.AwaitHoist`, the last
// middle-end pass), any await in an operand position with values already
// evaluated — a second-argument spawn join (`combineTwo(5, await t)`), two
// joins in one argument list, a constructor argument, a method-call argument
// (the receiver counts as a stacked operand), a nested await, a list element,
// an index expression, an interpolation segment, a `while` condition — died on
// MSIL with `InvalidProgramException` in the async-SM `MoveNext` (the CLR does
// not preserve the operand stack across a suspension), or crashed the compiler
// with an `emitPhaseBAwait` count mismatch for the nested-await shapes.  The
// JVM backend handled every position already; both targets now compile the
// same hoisted tree, so these cases pin the hoist's runtime values on both.
async func awaitInSecondArg(a: in Int): Int {
  scope {
    val t = spawn doubleIt(a)
    return combineTwo(5, await t)
  }
}

async func awaitsInBothArgs(a: in Int, b: in Int): Int {
  scope {
    val ta = spawn doubleIt(a)
    val tb = spawn addOne(b)
    return combineTwo(await ta, await tb)
  }
}

record PairBox {
  first: Int
  second: Int
}

async func ctorArgAwait(x: in Int): Int {
  val p = PairBox(first = 5, second = await addOne(x))
  return p.first * 100 + p.second
}

record Scaler {
  base: Int

  func scale(self: in Scaler, x: in Int, y: in Int): Int {
    self.base * 100 + x * 10 + y
  }
}

async func methodArgAwait(x: in Int): Int {
  val s = Scaler(base = 3)
  val firstPos = s.scale(await addOne(x), 1)
  val secondPos = s.scale(5, await doubleIt(x))
  return firstPos * 10000 + secondPos
}

async func nestedAwaits(x: in Int): Int {
  return combineTwo(5, await addOne(await doubleIt(x)))
}

async func interpAwait(x: in Int): String {
  val a = 7
  return "a=${a} b=${await addOne(x)}"
}

// The list-literal case asserts through `.count` and the index case builds
// its list via `newList()` because MSIL list-LITERAL element reads are
// broken on main independently of async/await (`[9, 7]` then `xs[0]`
// returns garbage even in a plain function; `newList()` + `add` reads
// correctly) — a separate pre-existing silent miscompile this suite must
// not couple to.
async func listElemAwait(x: in Int): Int {
  val xs = [1, await addOne(x)]
  return xs.count * 100 + 5
}

async func indexAwait(x: in Int): Int {
  val xs: List[Int] = newList()
  xs.add(10)
  xs.add(20)
  xs.add(30)
  return xs[await addOne(x) - 4]
}

async func whileCondAwait(x: in Int): Int {
  var n = x
  var iters = 0
  while combineTwo(0, await addOne(n)) > 5 {
    n = n - 1
    iters = iters + 1
  }
  return n * 10 + iters
}

// `await` in an `if` condition inside a `scope { }` body (#5569 item 2
// family): the join happens while evaluating the branch condition, and a
// statement after the `if` is asserted.
async func awaitInIfCond(a: in Int): Int {
  var r = 0
  scope {
    val t = spawn doubleIt(a)
    if await t == a * 2 {
      r = 1
    } else {
      r = 2
    }
    r = r + 10
  }
  return r
}

// A spawned task that panics: `await` must propagate its failure (§7.4's
// first-failure-propagates guarantee).  On JVM the join helper `__lyric_await`
// unwraps the `ExecutionException` to its cause so the original panic message
// surfaces (not the executor's wrapper); on MSIL the async state machine rethrows
// the faulted task's exception.  Either way the awaiting caller observes a `Bug`
// carrying the task's message.
async func boomTask(): Int {
  panic("boom-in-spawned-task")
}

async func awaitFailingSpawn(): Unit {
  scope {
    val t = spawn boomTask()
    val _ = await t
  }
}

// A scope BODY that panics while a spawned task is still running (#5569 item
// 3): the Throwable must propagate out of the scope instead of parking behind
// the executor close.  Before the fix, the exception path of the synthesized
// close-defer ran `ExecutorService.close()`, which waits for every submitted
// task — with `loiter` live the rethrow never happened and the error was a
// silent hang in `ThreadPerTaskExecutor.close`; now that path runs
// `shutdownNow()` (interrupt, no wait) and rethrows immediately.
//
// A plain (non-async) func: it awaits nothing, and the MSIL async-SM
// closure pre-pass has a pre-existing hole for a `var` captured by a lambda
// declared inside a `scope` body (it panics "captured mutable local 'go' was
// not hoisted"); the plain-func pre-pass handles the shape correctly.
//
// `loiter` is concurrency-conditional so the test is safe on MSIL's
// degenerate-synchronous `spawn`: it polls the hoisted `go` flag (set AFTER
// the spawn statement) for up to one second.  Run inline (MSIL), `go` is
// still 0, so it exits after the bounded wait and the panic follows.  Run
// concurrently (JVM), it observes `go == 1` and loiters in interruptible
// sleeps until `shutdownNow()` interrupts it — before the fix this loitering
// made the hang unbounded, which is exactly the regression this case guards.
func panicWithUnfinishedSpawn(): Unit {
  var go = 0
  scope {
    val loiter = { ->
      var waited = 0
      while go == 0 and waited < 20 {
        sleepMillis(50)
        waited = waited + 1
      }
      while go == 1 {
        sleepMillis(200)
      }
      0
    }
    val t = spawn loiter()
    go = 1
    panic("boom-in-scope-body")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────
// Each `test` body `await`s the async helper: on MSIL an `async func` returns a
// `Task<T>`, and `await` in this synchronous test context resolves it via
// `GetAwaiter().GetResult()` (the `emitBlockingAwait` path, as `async_sm_self_test`
// does); on JVM the helper already returns the value synchronously, so `await` of
// a non-`Future` is a pass-through.  Either way the assertion sees the `Int`.
test "scope with two spawns, early return, sums awaited results" {
  assertEqualInt(await sumDoublesReturn(3, 4), 14, "double(3)+double(4)")
  assertEqualInt(await sumDoublesReturn(10, 20), 60, "double(10)+double(20)")
  assertEqualInt(await sumDoublesReturn(0, 0), 0, "double(0)+double(0)")
}

test "scope with two spawns, fall-off, sums awaited results" {
  assertEqualInt(await sumDoublesFallOff(3, 4), 14, "fall-off double(3)+double(4)")
  assertEqualInt(await sumDoublesFallOff(7, 8), 30, "fall-off double(7)+double(8)")
}

test "bare spawn without a scope round-trips through await" {
  assertEqualInt(await bareSpawnRoundTrip(21), 42, "bare double(21)")
  assertEqualInt(await bareSpawnRoundTrip(1), 2, "bare double(1)")
}

test "three concurrent spawns combine correctly" {
  // double(5) + addOne(6) + double(7) = 10 + 7 + 14 = 31
  assertEqualInt(await sumThree(5, 6, 7), 31, "double(5)+addOne(6)+double(7)")
}

test "parenthesized spawn initializers unbox for arithmetic" {
  assertEqualInt(await parenSpawnSum(3, 4), 14, "paren double(3)+double(4)")
  assertEqualInt(await parenSpawnSum(10, 20), 60, "paren double(10)+double(20)")
}

test "unit-returning spawned task joins with no leaked value" {
  assertEqualInt(await spawnUnitTask(4), 12, "unit-task then x*3")
}

test "spawn-binding name reused across sibling scopes compiles and joins" {
  assertEqualInt(await reusedBindingName(3, 4), 14, "double(3)+double(4) reused name")
  assertEqualInt(await reusedBindingName(10, 5), 30, "double(10)+double(5) reused name")
}

test "reference-typed spawn result checkcasts on await" {
  assertEqual(await spawnStringResult("bob"), "hi-bob", "greet(bob)")
  assertEqual(await spawnStringResult("x"), "hi-x", "greet(x)")
}

test "reassigned spawn handle awaits the second spawn's result" {
  // double(5) then addOne(10) = 10 + 11 = 21
  assertEqualInt(await reassignedSpawnHandle(5, 10), 21, "double(5)+addOne(10)")
  assertEqualInt(await reassignedSpawnHandle(2, 2), 7, "double(2)+addOne(2)")
}

test "nested scopes submit spawns to the innermost executor" {
  // double(5) + addOne(10) = 10 + 11 = 21
  assertEqualInt(await nestedScopeSpawns(5, 10), 21, "nested double(5)+addOne(10)")
  // double(3) + addOne(3) = 6 + 4 = 10
  assertEqualInt(await nestedScopeSpawns(3, 3), 10, "nested double(3)+addOne(3)")
}

test "compound assignment with await in a scope runs the whole body" {
  // x = 1 + double(5) + addOne(6) = 1 + 10 + 7 = 18; after = 7
  assertEqualInt(await compoundAwaitAssign(5, 6), 18007, "compound awaits then trailing statement")
  // x = 1 + double(2) + addOne(0) = 1 + 4 + 1 = 6; after = 7
  assertEqualInt(await compoundAwaitAssign(2, 0), 6007, "compound awaits, small values")
}

test "await in call-argument position inside a scope" {
  // combineTwo(double(4), 5) + combineTwo(addOne(6), 6) = 85 + 76 = 161; *10 + 3 = 1613
  assertEqualInt(await awaitInCallArg(4, 6), 1613, "spawn joins as call arguments")
}

test "#5606: await in second-argument position inside a scope" {
  // combineTwo(5, double(4)) = 50 + 8 = 58
  assertEqualInt(await awaitInSecondArg(4), 58, "second-arg spawn join")
}

test "#5606: two awaits in one argument list inside a scope" {
  // combineTwo(double(4), addOne(6)) = 80 + 7 = 87
  assertEqualInt(await awaitsInBothArgs(4, 6), 87, "both arguments are spawn joins")
}

test "#5606: await in a constructor argument" {
  // PairBox(5, addOne(4)) -> 5 * 100 + 5
  assertEqualInt(await ctorArgAwait(4), 505, "ctor second-field await")
}

test "#5606: await in method-call arguments (receiver stacked)" {
  // scale(addOne(4), 1) = 300 + 50 + 1 = 351; scale(5, double(4)) = 300 + 50 + 8 = 358
  assertEqualInt(await methodArgAwait(4), 3510358, "first- and second-position method-arg awaits")
}

test "#5606: nested awaits stay correctly ordered" {
  // addOne(double(4)) = 9; combineTwo(5, 9) = 59
  assertEqualInt(await nestedAwaits(4), 59, "await addOne(await doubleIt(x))")
}

test "#5606: await in an interpolation segment" {
  assertEqual(await interpAwait(4), "a=7 b=5", "interpolated await after a text+expr prefix")
}

test "#5606: await in a list-literal element" {
  // [1, addOne(4)].count = 2 -> 2 * 100 + 5
  assertEqualInt(await listElemAwait(4), 205, "second list element is an await")
}

test "#5606: await in an index expression" {
  // xs[addOne(4) - 4] = xs[1] = 20
  assertEqualInt(await indexAwait(4), 20, "receiver stacked across an index await")
}

test "#5606: await in a while condition re-evaluates per iteration" {
  // n: 8..5 iterate (addOne(n) > 5), stop at n = 4 -> 4 * 10 + 4
  assertEqualInt(await whileCondAwait(8), 44, "hoisted condition inside the loop rewrite")
}

test "await in an if condition inside a scope" {
  assertEqualInt(await awaitInIfCond(9), 11, "join inside the branch condition")
}

test "spawned task that panics propagates through await" {
  // The closure is a non-async lambda, so its `await` uses the blocking resolve
  // path and V0012 (await-in-try, async-only) does not apply; the try/catch that
  // observes the panic lives inside `assertPanics`.  This asserts the failure
  // *propagates* (§7.4's first-failure guarantee) — the join surfaces the faulted
  // task's exception rather than swallowing it or hanging.  The exact
  // cause-unwrap (JVM `ExecutionException` → original message) is verified
  // separately end-to-end; message-substring matching through the test-synth
  // is avoided here as brittle.
  assertPanics("failing spawn propagates", { -> await awaitFailingSpawn() })
}

test "a panic escaping a scope body propagates without waiting for unfinished spawns" {
  // Before the #5569 item-3 fix this HUNG on JVM (the close-defer's exception
  // path joined the still-loitering task before the rethrow); the fix aborts
  // the executor via shutdownNow and rethrows immediately, so the panic
  // surfaces here.  On MSIL the degenerate-synchronous spawn runs `loiter`
  // inline (bounded, `go` still 0) and the panic follows it.
  assertPanics("scope-body panic propagates past a live spawned task", { -> panicWithUnfinishedSpawn() })
}
