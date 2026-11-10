//! tests/mq_concurrency_jvm_tests.l — the in-process broker under real
//! threads on `--target jvm`.  Publishers and consumers share one queue; every
//! message must come out exactly once.
@cfg(target = "jvm")
@test_module
package Mq.MqConcurrencyJvmTests

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

func idFor(worker: in Int, n: in Int): String {
  "w" + worker.toString() + "-m" + n.toString()
}

ref record Drained {
  var ids: List[String]
}

func publishAll(q: in Mq.NativeQueue, worker: in Int, count: in Int): Unit {
  var n = 0
  while n < count {
    val m = Mq.Message(id = idFor(worker, n), body = "b", headers = [], deliveryCount = 0)
    match Mq.publish(q, m) {
      case Ok(_) -> ()
      case Err(e) -> panic("publish failed: " + e)
    }
    n = n + 1
  }
}

func takeId(d: in Drained, m: in Mq.Message): Result[Unit, String] {
  d.ids.add(m.id)
  return Ok(())
}

func drain(q: in Mq.NativeQueue, d: in Drained): Unit {
  var more = true
  while more {
    match Mq.consume(q, 0, { m -> takeId(d, m) }) {
      case Ok(_) -> ()
      case Err(_) -> {
        more = false
      }
    }
  }
}

func countDistinct(all: in List[Drained]): Int {
  val seen: Map[String, Bool] = newMap()
  for d in all.toArray() {
    for id in d.ids.toArray() {
      seen[id] = true
    }
  }
  return seen.count
}

func totalDelivered(all: in List[Drained]): Int {
  var total = 0
  for d in all.toArray() {
    total = total + d.ids.count
  }
  return total
}

test "concurrent publishers and consumers deliver every message exactly once" {
  val q = unwrapResult(Mq.connectTo("inmemory://concurrency", "shared"))
  val perWorker = 300
  runAll(
    [
      { -> publishAll(q, 0, perWorker) },
      { -> publishAll(q, 1, perWorker) },
      { -> publishAll(q, 2, perWorker) },
      { -> publishAll(q, 3, perWorker) }
    ]
  )
  val drains: List[Drained] = newList()
  var i = 0
  while i < 3 {
    drains.add(Drained(ids = newList()))
    i = i + 1
  }
  runAll([{ -> drain(q, drains[0]) }, { -> drain(q, drains[1]) }, { -> drain(q, drains[2]) }])
  assertEqualInt(totalDelivered(drains), 4 * perWorker, "every published message was delivered")
  assertEqualInt(countDistinct(drains), 4 * perWorker, "no message was delivered twice")
}

test "concurrent connect hands out distinct queues" {
  val queues: List[Mq.NativeQueue] = newList()
  var i = 0
  while i < 8 {
    queues.add(unwrapResult(Mq.connectTo("inmemory://concurrency", "q" + i.toString())))
    i = i + 1
  }
  val ids: Map[Int, Bool] = newMap()
  for q in queues.toArray() {
    ids[q.queueId] = true
  }
  assertEqualInt(ids.count, 8, "eight connects, eight distinct handles")
}
