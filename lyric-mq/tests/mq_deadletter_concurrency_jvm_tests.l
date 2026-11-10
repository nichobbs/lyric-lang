//! tests/mq_deadletter_concurrency_jvm_tests.l: InProcessDeadLetterStore under real threads on --target jvm (#8950).
@cfg(target = "jvm")
@test_module
package Mq.MqDeadLetterConcurrencyJvmTests

import Std.Core
import Std.Collections
import Std.Testing
import Mq

extern type JThread = "java.lang.Thread"

func runAll(works: in List[() -> Unit]): Unit {
  var threads: List[JThread] = newList()
  var i = 0
  while i < works.count {
    val w = works[i]
    val t = JThread.new({ -> w() })
    t.start()
    threads.add(t)
    i = i + 1
  }
  var j = 0
  while j < threads.count {
    threads[j].join()
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
