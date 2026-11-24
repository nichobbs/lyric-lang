//! Ws.Kernel.Net concurrent dictionary (`jvm` and `native`) — a `Map` behind
//! one `WsLock`, in plain Lyric. The `dotnet` twin (`_kernel/net/ws_prims.l`)
//! uses `System.Collections.Concurrent.ConcurrentDictionary` instead. A reader
//! or writer holds the lock only for the lookup, never across I/O.
//!
//! Only active when compiled with feature = "jvm" or "native".
@cfg(any(feature = "jvm", feature = "native"))
@io
package Ws.Kernel.Net

import Std.Core
import Std.Collections

// ─── Concurrent dictionary ───────────────────────────────────────────────────
record ConcurrentDict[K, V] {
  lock: WsLock
  items: Map[K, V]
}

func newConcurrentDict[K, V](): ConcurrentDict[K, V] {
  val items: Map[K, V] = newMap()
  ConcurrentDict(lock = newWsLock(), items = items)
}

func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  match mapGet(dict.items, key) {
    case Some(found) -> {
      value = found
      true
    }
    case None -> false
  }
}

func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  if dict.items.containsKey(key) {
    return false
  }
  dict.items.add(key, value)
  true
}

func cdTryRemove[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  match mapGet(dict.items, key) {
    case Some(found) -> {
      value = found
      val _ = dict.items.remove(key)
      true
    }
    case None -> false
  }
}
