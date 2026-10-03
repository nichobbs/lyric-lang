//! task_handle_api_self_test.l - the `Std.Task` spawn-handle API (docs/68 §5):
//! `waitFor`, `isDone` and `awaitAll` over `Task[T]` handles, on `--target
//! dotnet` and `--target jvm`.  Every handle is spawned inside a `scope { }`
//! (V0034) and every task is finished before the scope exits.
@test_module
package Lyric.TaskHandleApiSelfTest

import Std.Collections
import Std.Core
import Std.Task
import Std.Testing

async func slowValue(ms: in Int, v: in Int): Int {
  await delay(ms)
  return v
}

func boom(): Int {
  panic("boom")
}

async func failingTask(): Int {
  return boom()
}

async func timesOutThenFinishes(): Bool {
  scope {
    val t = spawn slowValue(400, 7)
    val early = waitFor(t, 10)
    val late = waitFor(t, 20000)
    return (not early) and late
  }
}

async func waitForIsRepeatable(): Bool {
  scope {
    val t = spawn slowValue(20, 1)
    val a = waitFor(t, 20000)
    val b = waitFor(t, 20000)
    val c = waitFor(t, 0)
    return a and b and c
  }
}

async func isDoneBeforeAndAfter(): Bool {
  scope {
    val t = spawn slowValue(400, 3)
    val before = isDone(t)
    val joined = await t
    val after = isDone(t)
    return (not before) and after and joined == 3
  }
}

async func awaitAllKeepsInputOrder(): List[Int] {
  scope {
    val ts: List[Task[Int]] = newList()
    ts.add(spawn slowValue(120, 1))
    ts.add(spawn slowValue(10, 2))
    ts.add(spawn slowValue(60, 3))
    return awaitAll(ts)
  }
}

async func awaitAllOfNothing(): Int {
  scope {
    val ts: List[Task[Int]] = newList()
    val results = awaitAll(ts)
    return results.count
  }
}

async func awaitAllWithFailure(): Int {
  scope {
    val ts: List[Task[Int]] = newList()
    ts.add(spawn slowValue(10, 1))
    ts.add(spawn failingTask())
    val results = awaitAll(ts)
    return results.count
  }
}

async func waitThenAwaitFailed(seen: in List[Bool]): Int {
  scope {
    val t = spawn failingTask()
    seen.add(waitFor(t, 20000))
    return await t
  }
}

test "waitFor times out on a slow task, then reports it finished" {
  assertTrue(await timesOutThenFinishes(), "false at 10 ms, true once the task completes")
}

test "waitFor can be called repeatedly on a finished task" {
  assertTrue(await waitForIsRepeatable(), "repeated waitFor stays true")
}

test "isDone is false before and true after the task finishes" {
  assertTrue(await isDoneBeforeAndAfter(), "isDone tracks completion")
}

test "awaitAll returns results in input order, not completion order" {
  val xs = await awaitAllKeepsInputOrder()
  assertEqualInt(xs.count, 3, "three results")
  assertEqualInt(xs[0], 1, "first input first")
  assertEqualInt(xs[1], 2, "second input second")
  assertEqualInt(xs[2], 3, "third input third")
}

test "awaitAll of an empty list is an empty list" {
  assertEqualInt(await awaitAllOfNothing(), 0, "no tasks, no results")
}

test "awaitAll raises a failed task's failure" {
  assertPanics("failing task propagates through awaitAll", { -> val r = await awaitAllWithFailure() })
}

test "waitFor reports a failed task finished and await raises its failure" {
  val seen: List[Bool] = newList()
  assertPanics("await raises the failure", { -> val r = await waitThenAwaitFailed(seen) })
  assertEqualInt(seen.count, 1, "waitFor returned")
  assertTrue(seen[0], "waitFor returned true for the failed task, not a timeout")
}
