//! task_shadow_self_test.l - a user-declared generic `record Task[T]` shadows
//! the built-in `Task[T]` spawn handle (docs/68, D166) on both backends:
//! parameters, returns and field reads resolve to the user's record, not to a
//! task handle or to `Std.Task`'s kernel record.
@test_module
package Lyric.TaskShadowSelfTest

import Std.Core
import Std.Testing

record Task[T] {
  value: T
  label: String
}

func makeTask(n: in Int): Task[Int] {
  return Task(value = n, label = "job")
}

func valueOf(t: in Task[Int]): Int {
  return t.value
}

func labelOf(t: in Task[Int]): String {
  return t.label
}

test "a user Task[T] record field read through a parameter" {
  val t = makeTask(41)
  assertEqualInt(valueOf(t), 41, "value read through a Task[Int] parameter")
  assertEqual(labelOf(t), "job", "label read through a Task[Int] parameter")
}

test "a user Task[T] record returned from a function" {
  assertEqualInt(makeTask(7).value, 7, "field read on a returned Task[Int]")
}
