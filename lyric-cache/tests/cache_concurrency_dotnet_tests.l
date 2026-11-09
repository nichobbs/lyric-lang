//! tests/cache_concurrency_dotnet_tests.l — `InProcessCacheStore` under real
//! threads on `--target dotnet`.
//!
//! The store is shared process-wide by `Cache.Aspects`, so concurrent `set` /
//! `get` / `delete` must not lose updates or corrupt the store.  Each worker
//! owns a disjoint key range, so the expected final state is deterministic:
//! when the store was an unsynchronised record, concurrent `Dictionary` / `List`
//! mutation lost entries and threw, and these checks failed.
@cfg(target = "dotnet")
@test_module
package Cache.CacheConcurrencyDotnetTests

import Std.Core
import Std.Testing
import Cache

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

func keyFor(worker: in Int, n: in Int): String {
  "w" + worker.toString() + "-k" + n.toString()
}

func hammer(store: in CacheStore, worker: in Int, perWorker: in Int): Unit {
  var n = 0
  while n < perWorker {
    Cache.set(store, keyFor(worker, n), "v" + n.toString())
    n = n + 1
  }
  var d = 0
  while d < perWorker {
    if d % 3 == 0 {
      Cache.delete(store, keyFor(worker, d))
    }
    d = d + 1
  }
}

test "concurrent set and delete on disjoint keys lose no update" {
  val store = Cache.inProcessWithCapacity(100000)
  val workers = 4
  val perWorker = 1500
  val t0 = taskRun({ -> hammer(store, 0, perWorker) })
  val t1 = taskRun({ -> hammer(store, 1, perWorker) })
  val t2 = taskRun({ -> hammer(store, 2, perWorker) })
  val t3 = taskRun({ -> hammer(store, 3, perWorker) })
  taskWait(t0)
  taskWait(t1)
  taskWait(t2)
  taskWait(t3)

  var missing = 0
  var resurrected = 0
  var w = 0
  while w < workers {
    var n = 0
    while n < perWorker {
      val present = match Cache.get(store, keyFor(w, n)) { case Some(_) -> true; case None -> false }
      if n % 3 == 0 {
        if present {
          resurrected = resurrected + 1
        }
      } else if not present {
        missing = missing + 1
      }
      n = n + 1
    }
    w = w + 1
  }
  assertEqualInt(missing, 0, "every key that was set and not deleted is still present")
  assertEqualInt(resurrected, 0, "every deleted key is gone")
}

func churn(store: in CacheStore, worker: in Int, rounds: in Int): Unit {
  var i = 0
  while i < rounds {
    val k = keyFor(worker, i % 40)
    Cache.set(store, k, "x")
    val _ = Cache.get(store, k)
    if i % 7 == 0 {
      Cache.delete(store, k)
    }
    i = i + 1
  }
}

test "concurrent churn under a small capacity keeps the store consistent" {
  val store = Cache.inProcessWithCapacity(25)
  val t0 = taskRun({ -> churn(store, 0, 3000) })
  val t1 = taskRun({ -> churn(store, 1, 3000) })
  val t2 = taskRun({ -> churn(store, 2, 3000) })
  val t3 = taskRun({ -> churn(store, 3, 3000) })
  taskWait(t0)
  taskWait(t1)
  taskWait(t2)
  taskWait(t3)

  Cache.set(store, "after", "ok")
  match Cache.get(store, "after") {
    case Some(v) -> assertEqual(v, "ok", "the store still works after the churn")
    case None -> assertTrue(false, "a key set after the churn must be readable")
  }
  Cache.clear(store)
  match Cache.get(store, "after") {
    case Some(_) -> assertTrue(false, "clear must empty the store")
    case None -> ()
  }
}
