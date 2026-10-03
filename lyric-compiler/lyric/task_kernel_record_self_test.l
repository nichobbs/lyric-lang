//! task_kernel_record_self_test.l - the built-in `Task[T]` spawn handle (D166)
//! next to `Std.Task` in the same bundle.  On `--target jvm` `Std.Task`'s
//! kernel declares a non-generic `record Task`, registered under the bare
//! constructor name `Task`; a `Task[Int]` handle must never be narrowed to that
//! record (a `ClassCastException` / `NoClassDefFoundError` at run time).
//! Covers a handle through a parameter, a generic specialisation and a
//! returned handle-typed value with `import Std.Task` in scope.
@test_module
package Lyric.TaskKernelRecordSelfTest

import Std.Core
import Std.Task
import Std.Testing

async func triple(n: in Int): Int {
  return n * 3
}

func identityOver[T](x: in T): T {
  return x
}

func joinHandle(t: in Task[Int]): Int {
  return await t
}

async func throughParameter(n: in Int): Int {
  scope {
    val t = spawn triple(n)
    return joinHandle(t)
  }
}

async func throughGeneric(n: in Int): Int {
  scope {
    val t = identityOver(spawn triple(n))
    return await t
  }
}

async func annotatedLocal(n: in Int): Int {
  scope {
    val t: Task[Int] = spawn triple(n)
    return await t
  }
}

test "a Task[Int] handle through a parameter with Std.Task imported" {
  assertEqualInt(await throughParameter(4), 12, "parameter")
}

test "a generic over a Task[Int] handle with Std.Task imported" {
  assertEqualInt(await throughGeneric(5), 15, "generic")
}

test "an annotated Task[Int] local with Std.Task imported" {
  assertEqualInt(await annotatedLocal(6), 18, "annotated local")
}
