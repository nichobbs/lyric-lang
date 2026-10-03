//! async_extern_self_test.l — regression test for @externTarget async
//! synchronous unwrap (Band 3 Phase A, D085 / D-progress-415, epic #2070)
//! and the Phase 4 `await externFn()` pass-through (D091 / D-progress-440).
//!
//! Without `await`: @externTarget async func blocks synchronously and returns T.
//! With `await`:    the await keyword is a pass-through — the value is already
//!                  resolved, so isTaskTypeMsil returns false and GetAwaiter is
//!                  never called.  Both spellings produce identical results.
//!
//! Also covers spawn: `spawn asyncFn()` returns a Task<T> handle; a subsequent
//! `await handle` unwraps it via the blocking path in non-SM context.  The
//! handle also instantiates a generic function over the task, not over the
//! callee's logical result, so a generic `@externInstance` receiver
//! (`Task.Wait`) is bound to a real task for a `Unit`- and a value-returning
//! callee alike.
//!
//!   lyric test lyric-compiler/lyric/async_extern_self_test.l
@test_module
package Lyric.AsyncExternSelfTest

import Std.Core
import Std.Task
import Std.Testing

extern type StringReader = "System.IO.StringReader"

// Non-void async path: StringReader.ReadToEndAsync() returns Task<string>;
// the emitter must append callvirt Task`1<String>::get_Result() so the
// Lyric caller receives String, not Task<String>.
@externTarget("System.IO.StringReader..ctor")
func newStringReader(content: in String): StringReader = ()

@externTarget("System.IO.StringReader.ReadToEndAsync")
@externInstance
async func stringReaderReadToEnd(reader: in StringReader): String = ()

// Void async path: Task.Delay(int) returns Task (non-generic); the emitter
// must append callvirt Task::Wait() so the call blocks until the Task
// (already completed for ms=0) finishes.
@externTarget("System.Threading.Tasks.Task.Delay")
async func taskDelay(ms: in Int) = ()

test "non-void async extern returns T not Task<T>" {
  val reader = newStringReader("hello async")
  val content = stringReaderReadToEnd(reader)
  assertEqual(content, "hello async", "ReadToEndAsync should return the string content, not a Task<string> object")
}

test "void async extern completes without error" {
  taskDelay(0)
}

// Phase 4: `await externFn()` is a no-op pass-through in non-async context.
// The blocking wrapper already resolved T; isTaskTypeMsil(T) = false so no
// GetAwaiter call is emitted — the value flows through unchanged.
test "await non-void async extern is pass-through" {
  val reader = newStringReader("hello await extern")
  val content = await stringReaderReadToEnd(reader)
  assertEqual(content, "hello await extern", "await on blocking extern should pass through resolved T")
}

test "await void async extern is pass-through" {
  await taskDelay(0)
}

// #5560: an async INSTANCE extern declared WITHOUT `@externInstance` must
// still emit an instance call.  The metadata-direct staticness correction
// (`hasThis` from reference-assembly metadata) previously only ran on the
// non-async @externTarget path, so this shape emitted `call` with the
// receiver as arg0 of a static signature and faulted at run time with
//   MissingMethodException: Method not found:
//     'Task`1<String> System.IO.StringReader.ReadToEndAsync(System.IO.StringReader)'.
// This is exactly the shape of every async send in the Std.Http kernel
// (`HttpClient.SendAsync` / `GetAsync` / `PostAsync`).
@externTarget("System.IO.StringReader.ReadToEndAsync")
async func stringReaderReadToEndNoHint(reader: in StringReader): String = ()

test "async instance extern without @externInstance resolves via metadata" {
  val reader = newStringReader("hello nohint")
  val content = stringReaderReadToEndNoHint(reader)
  assertEqual(content, "hello nohint", "async instance extern without @externInstance must emit an instance call")
}

test "await async instance extern without @externInstance is pass-through" {
  val reader = newStringReader("hello await nohint")
  val content = await stringReaderReadToEndNoHint(reader)
  assertEqual(content, "hello await nohint", "await on the no-hint blocking extern should pass through resolved T")
}

// A `spawn` handle is the callee's task object, so a generic over the handle
// specialises over the task.  The type checker types the handle as the
// callee's logical result, which used to specialise `T` as `Unit` (a `void`
// parameter, `TypeLoadException: The signature is incorrect.` as the class
// loaded) or as `Int` (an unboxed primitive handed a `Task<int>`, an access
// violation).  `Task.Wait(int)` is the receiver the generic stands for.
@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWaitMs[T](t: in T, timeoutMs: in Int): Bool = false

async func spawnedUnitWork(ms: in Int): Unit {
  await Std.Task.delay(ms)
  return ()
}

async func spawnedIntWork(ms: in Int): Int {
  await Std.Task.delay(ms)
  return 41
}

test "generic extern receiver bound to a spawn handle of a Unit-returning async func" {
  val t = spawn spawnedUnitWork(10)
  assertTrue(taskWaitMs(t, 10000), "the spawned Unit-returning task completes within the budget")
}

test "generic extern receiver bound to a spawn handle of a value-returning async func" {
  val t = spawn spawnedIntWork(10)
  assertTrue(taskWaitMs(t, 10000), "the spawned Int-returning task completes within the budget")
  assertEqualInt(await t, 41, "the handle still awaits to the callee's result after the bounded wait")
}

test "generic extern receiver on a spawn handle reports a timeout as false and keeps the task" {
  val t = spawn spawnedIntWork(400)
  assertFalse(taskWaitMs(t, 1), "a 1 ms wait on a 400 ms task times out")
  assertTrue(taskWaitMs(t, 10000), "the same task completes on a later, longer wait")
  assertEqualInt(await t, 41, "the task's result is intact after the timed-out wait")
}

test "generic extern receiver bound to a spawn call used directly as the argument" {
  assertTrue(taskWaitMs(spawn spawnedUnitWork(10), 10000), "a spawn expression passed straight to the generic")
}

test "generic extern receiver bound to a parenthesised spawn operand" {
  val t = spawn (spawnedIntWork(10))
  assertTrue(taskWaitMs(t, 10000), "spawn of a parenthesised async call still hands the generic a task")
  assertEqualInt(await t, 41, "the handle awaits to the callee's result")
}

// The specialisation is over the task for any generic, not only an extern
// receiver, and the synthesized `Task` needs no import in the calling file
// beyond what this file already has.
func keepSecond[T](x: in T, n: in Int): Int {
  n
}

test "an ordinary generic over a spawn handle specialises over the task" {
  val a = spawn spawnedIntWork(10)
  val b = spawn spawnedUnitWork(10)
  assertEqualInt(keepSecond(a, 1), 1, "Int-returning handle")
  assertEqualInt(keepSecond(b, 2), 2, "Unit-returning handle")
  assertEqualInt(await a, 41, "the handle still awaits to its result")
}
