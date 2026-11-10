//! tests/cache_concurrency_jvm_tests.l — `InProcessCacheStore` under real
//! threads on `--target jvm`.
//!
//! The store is shared process-wide by `Cache.Aspects`, so concurrent `set` /
//! `get` / `delete` must not lose updates or corrupt the store.  Each worker
//! owns a disjoint key range, so the expected final state is deterministic:
//! when the store was an unsynchronised record, concurrent `Dictionary` / `List`
//! mutation lost entries and threw, and these checks failed.
@cfg(target = "jvm")
@test_module
package Cache.CacheConcurrencyJvmTests

import Std.Core
import Std.Collections
import Std.Testing
import Cache

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
  runAll(
    [
      { -> hammer(store, 0, perWorker) },
      { -> hammer(store, 1, perWorker) },
      { -> hammer(store, 2, perWorker) },
      { -> hammer(store, 3, perWorker) }
    ]
  )

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
  runAll(
    [
      { -> churn(store, 0, 3000) },
      { -> churn(store, 1, 3000) },
      { -> churn(store, 2, 3000) },
      { -> churn(store, 3, 3000) }
    ]
  )

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
