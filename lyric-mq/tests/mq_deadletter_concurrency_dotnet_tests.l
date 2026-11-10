//! tests/mq_deadletter_concurrency_dotnet_tests.l: InProcessDeadLetterStore under real threads on --target dotnet (#8950).
@cfg(target = "dotnet")
@test_module
package Mq.MqDeadLetterConcurrencyDotnetTests

import Std.Core
import Std.Collections
import Std.Testing
import Mq

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

func runAll(works: in List[() -> Unit]): Unit {
  var tasks: List[Task] = newList()
  var i = 0
  while i < works.count {
    tasks.add(taskRun(works[i]))
    i = i + 1
  }
  var j = 0
  while j < tasks.count {
    taskWait(tasks[j])
    j = j + 1
  }
}

func dlEntry(worker: in Int, n: in Int): Mq.DeadLetterEntry {
  val m = Mq.Message(id = "w" + worker.toString() + "-" + n.toString(), body = "b", headers = [], deliveryCount = 0)
  return Mq.DeadLetterEntry(message = m, reason = "r", failedAt = 1i64)
}

func appendMany(store: in Mq.DeadLetterStore, worker: in Int, count: in Int): Unit {
  var n = 0
  while n < count {
    store.append(dlEntry(worker, n))
    n = n + 1
  }
}

test "concurrent appends lose no entry below capacity" {
  val store = Mq.inProcessDeadLetterStore(100000)
  runAll(
    [
      { -> appendMany(store, 0, 500) },
      { -> appendMany(store, 1, 500) },
      { -> appendMany(store, 2, 500) },
      { -> appendMany(store, 3, 500) }
    ]
  )
  assertEqualInt(store.count(), 2000, "every appended entry is kept")
  assertEqualInt(store.list().length, 2000, "list agrees with count")
}

test "concurrent appends at capacity never exceed it" {
  val store = Mq.inProcessDeadLetterStore(50)
  runAll(
    [
      { -> appendMany(store, 0, 500) },
      { -> appendMany(store, 1, 500) },
      { -> appendMany(store, 2, 500) },
      { -> appendMany(store, 3, 500) }
    ]
  )
  assertEqualInt(store.count(), 50, "the store holds exactly its capacity")
}
