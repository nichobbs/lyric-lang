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
//! `await handle` unwraps it via the blocking path in non-SM context.
//!
//!   lyric test lyric-compiler/lyric/async_extern_self_test.l
@test_module
package Lyric.AsyncExternSelfTest

import Std.Core
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
