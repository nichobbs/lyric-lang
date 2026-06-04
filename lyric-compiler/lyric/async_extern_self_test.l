// async_extern_self_test.l — regression test for @externTarget async
// synchronous unwrap (Band 3 Phase A, D085 / D-progress-415, epic #2070).
//
// Before this fix, @externTarget async func silently left a Task<T> on the
// stack where callers expected T — a silent miscompile on every async BCL
// call.  This test exercises both unwrap paths end-to-end through the
// self-hosted Msil.Bridge and asserts correct runtime values:
//
//   - non-void path: callvirt Task`1<String>::get_Result()
//     via StringReader.ReadToEndAsync() which returns Task<string>
//     immediately from an in-memory buffer (no IO, no network).
//
//   - void path: callvirt Task::Wait()
//     via Task.Delay(0) which returns a Task that completes immediately.
//
//   lyric test lyric-compiler/lyric/async_extern_self_test.l

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
  val reader  = newStringReader("hello async")
  val content = stringReaderReadToEnd(reader)
  assertEqual(content, "hello async",
    "ReadToEndAsync should return the string content, not a Task<string> object")
}

test "void async extern completes without error" {
  taskDelay(0)
  assertTrue(true, "void async extern returned after Task::Wait()")
}
