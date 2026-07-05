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
//!   - a `Unit`-returning spawned task (the boxed-null Callable return).
@test_module
package Lyric.AsyncSpawnSelfTest

import Std.Core
import Std.Testing

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
