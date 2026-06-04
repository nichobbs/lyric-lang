// Ws.Kernel.Net — in-process WebSocket connection registry and rate limiter.
//
// Path-finder scope (#733, Phase 6): pure-Lyric implementation.  Real
// ASP.NET Core WebSocket integration (HTTP upgrade, MessageReceived loop,
// Kestrel binding) is tracked under #778 — that path requires the
// lyric-web Kestrel shim.
//
// `send` / `broadcast` validate bookkeeping state; per-connection frame
// buffering / real byte dispatch are deferred to #778.
//
// Only active when compiled with feature = "dotnet".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "dotnet")
package Ws.Kernel.Net

import Std.Core
import Std.Time

extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// ─── Connection registry ──────────────────────────────────────────────────────

record RegistryMeta {
  var maxMessageSizeBytes: Int = 1024
  var pingIntervalMs:      Int = 0
  var openCount:           Int = 0
}

record ConnState {
  var isOpen: Bool = false
}

// Locked to allocate sequential registry handles atomically.
record HandleCounter {
  var next: Int = 0
}

val handleCounter: HandleCounter                     = HandleCounter()
val registryMap:  ConcurrentDict[Int, RegistryMeta]  = newConcurrentDict()
// connMap is populated by registerConnection (the HTTP upgrade entry point).
// That function is deferred to #778 (lyric-web Kestrel shim); until then,
// send/isConnected/connectionCount operate on an empty map in path-finder scope.
val connMap:      ConcurrentDict[String, ConnState]   = newConcurrentDict()

func connKey(registryHandle: in Int, connectionId: in String): String {
  return registryHandle.toString() + ":" + connectionId
}

// registerConnection is the HTTP upgrade entry point for #778.  It populates
// connMap so that send / isConnected / connectionCount become functional.
// Deferred until lyric-web provides the Kestrel HTTP upgrade shim.
func registerConnection(registryHandle: in Int, connectionId: in String): Result[Unit, String]
  requires: connectionId.length > 0
{
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  monitorEnter(meta)
  defer { monitorExit(meta) }
  val key = connKey(registryHandle, connectionId)
  val state = ConnState(isOpen = true)
  if not cdTryAdd(connMap, key, state) {
    return Err("connection '" + connectionId + "' already registered")
  }
  meta.openCount = meta.openCount + 1
  Ok(())
}

// Close a single connection under its per-entry lock.  Returns true if the
// connection was open (caller should decrement the registry open count).
func tryCloseConn(state: in ConnState): Bool {
  monitorEnter(state)
  defer { monitorExit(state) }
  if state.isOpen {
    state.isOpen = false
    return true
  }
  false
}

// Decrement the open-connection counter for `handle` under the registry lock.
func decrementOpenCount(handle: in Int): Unit {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, handle, meta) {
    monitorEnter(meta)
    defer { monitorExit(meta) }
    if meta.openCount > 0 {
      meta.openCount = meta.openCount - 1
    }
  }
}

@stable(since="0.1")
pub func createRegistry(maxMessageSizeBytes: in Int, pingIntervalMs: in Int): Result[Int, String]
  requires: maxMessageSizeBytes >= 1024
  requires: pingIntervalMs >= 0
{
  if maxMessageSizeBytes < 1024 {
    return Err("createRegistry: maxMessageSizeBytes must be >= 1024")
  }
  if pingIntervalMs < 0 {
    return Err("createRegistry: pingIntervalMs must be >= 0")
  }
  monitorEnter(handleCounter)
  defer { monitorExit(handleCounter) }
  handleCounter.next = handleCounter.next + 1
  val handle = handleCounter.next
  val meta = RegistryMeta(
    maxMessageSizeBytes = maxMessageSizeBytes,
    pingIntervalMs      = pingIntervalMs,
    openCount           = 0
  )
  val _ = cdTryAdd(registryMap, handle, meta)
  Ok(handle)
}

@stable(since="0.1")
pub func send(registryHandle: in Int, connectionId: in String, messageType: in String, data: in String): Result[Unit, String]
  requires: connectionId.length > 0
  requires: messageType.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if not cdTryGetValue(connMap, key, state) {
    return Err("unknown connection '" + connectionId + "'")
  }
  if not state.isOpen {
    return Err("connection '" + connectionId + "' is closed")
  }
  Ok(())
}

@stable(since="0.1")
pub func broadcast(registryHandle: in Int, messageType: in String, data: in String): Result[Unit, String]
  requires: messageType.length > 0
{
  var meta: RegistryMeta = default()
  if not cdTryGetValue(registryMap, registryHandle, meta) {
    return Err("unknown registry handle " + registryHandle.toString())
  }
  // Path-finder scope: per-connection frame dispatch deferred to #778.
  Ok(())
}

@stable(since="0.1")
pub func close(registryHandle: in Int, connectionId: in String, code: in Int, reason: in String): Result[Unit, String]
  requires: connectionId.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if not cdTryGetValue(connMap, key, state) {
    return Ok(())
  }
  val wasOpen = tryCloseConn(state)
  if wasOpen {
    decrementOpenCount(registryHandle)
  }
  Ok(())
}

@stable(since="0.1")
pub func connectionCount(registryHandle: in Int): Int {
  var meta: RegistryMeta = default()
  if cdTryGetValue(registryMap, registryHandle, meta) {
    return meta.openCount
  }
  return 0
}

@stable(since="0.1")
pub func isConnected(registryHandle: in Int, connectionId: in String): Bool
  requires: connectionId.length > 0
{
  val key = connKey(registryHandle, connectionId)
  var state: ConnState = default()
  if cdTryGetValue(connMap, key, state) {
    return state.isOpen
  }
  false
}

// ─── Rate limiter (tumbling window) ──────────────────────────────────────────
//
// Uses a tumbling (fixed-reset) 60-second window per key, NOT the sliding
// window that the deleted F# WsHost.fs used (which maintained per-message
// timestamps and filtered to the trailing 60s).  The tumbling window allows
// up to 2× the nominal rate at window boundaries; the production rate limiter
// (#778) should implement the sliding window if boundary bursting is a concern.
// The burst budget is one-shot: it does not refill when the window resets.

record RateEntry {
  var windowStartMs:  Long = 0i64
  var usedInWindow:   Int  = 0
  var burstAvailable: Int  = 0
}

// Single global lock serialises all rate-limiter mutations.
record RateLock {}

val rateLock:     RateLock                           = RateLock()
val rateLimitMap: ConcurrentDict[String, RateEntry]  = newConcurrentDict()

@stable(since="0.1")
pub func checkRateLimit(key: in String, messagesPerMinute: in Int, burstSize: in Int): Bool
  requires: key.length > 0
  requires: messagesPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = nowEpochMillis()
  monitorEnter(rateLock)
  defer { monitorExit(rateLock) }

  var entry: RateEntry = default()
  if not cdTryGetValue(rateLimitMap, key, entry) {
    val newEntry = RateEntry(
      windowStartMs  = nowMs,
      usedInWindow   = 0,
      burstAvailable = burstSize
    )
    val _ = cdTryAdd(rateLimitMap, key, newEntry)
    var entry2: RateEntry = default()
    if cdTryGetValue(rateLimitMap, key, entry2) {
      entry = entry2
    } else {
      entry = newEntry
    }
  }

  val elapsed: Long = nowMs - entry.windowStartMs
  if elapsed >= 60000i64 {
    entry.windowStartMs = nowMs
    entry.usedInWindow  = 0
  }

  if entry.usedInWindow < messagesPerMinute {
    entry.usedInWindow = entry.usedInWindow + 1
    return true
  }

  if entry.burstAvailable > 0 {
    entry.burstAvailable = entry.burstAvailable - 1
    entry.usedInWindow   = entry.usedInWindow + 1
    return true
  }

  false
}
