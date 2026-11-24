//! Std.HttpServerHost, the per-target concurrency seam of the shared HTTP
//! server driver (docs/73 slice S2, D786), on every target.
//!
//! Coverage: `startTask` runs its work on another thread; `Mutex` gives mutual
//! exclusion (a deliberately racy read-modify-write loses no update under the
//! lock) and is reentrant; `Semaphore` counts, `semTryWait` never blocks, a
//! `semWait` is woken by a later `semPost` from another thread and a post made
//! before the wait is not lost; `WorkerSet` joins every task, including tasks
//! added by tasks, and can be reused; `runGuarded` passes a clean run through
//! and, on dotnet and the JVM, reports a panic to `onFailure` (native has no
//! unwinding, D-N-003, so that case is compiled out there). The stress cases
//! hand closures to threads from a function that returns at once, the shape
//! behind the native closure-lifetime fix of #6797.
//!
//!   lyric test --target dotnet lyric-stdlib/tests/http_server_host_tests.l
//!   lyric test --target jvm lyric-stdlib/tests/http_server_host_tests.l
//!   lyric test --target native lyric-stdlib/tests/http_server_host_tests.l
@test_module
package Std.HttpServerHost.Tests

import Std.Core
import Std.Collections
import Std.HttpServerHost
import Std.String
import Std.Testing
import Std.Time as Time

ref record Counter {
  var n: Int
  var text: String
}

func newCounter(): Counter {
  Counter(n = 0, text = "")
}

// A read-modify-write with a yield-sized gap in the middle: without mutual
// exclusion concurrent increments overwrite each other.
func bumpUnderLock(m: in Mutex, c: in Counter, times: in Int): Unit {
  var i = 0
  while i < times {
    lock(m)
    val seen = c.n
    c.n = seen + 1
    unlock(m)
    i = i + 1
  }
}

// Starts `count` workers from a frame that is gone by the time they run, each
// closure capturing its own values.
func startWorkers(set: in WorkerSet, c: in Counter, m: in Mutex, count: in Int, perWorker: in Int): Int {
  var started = 0
  var i = 0
  while i < count {
    val step = perWorker
    if workerAdd(set, { -> bumpUnderLock(m, c, step) }) {
      started = started + 1
    }
    i = i + 1
  }
  started
}

func postAfter(s: in Semaphore, ms: in Int): Unit {
  startTask({ -> Time.sleepMillis(ms); semPost(s) })
}

func addOne(c: in Counter, m: in Mutex): Unit {
  lock(m)
  c.n = c.n + 1
  unlock(m)
}

func startMany(s: in Semaphore, count: in Int): Unit {
  var i = 0
  while i < count {
    val tag = i
    startTask({ -> if tag >= 0 { semPost(s) } })
    i = i + 1
  }
}

func spawnNested(set: in WorkerSet, c: in Counter, m: in Mutex): Unit {
  val _ = workerAdd(
    set,
    { -> Time.sleepMillis(30); val _ = workerAdd(set, { -> Time.sleepMillis(30); addOne(c, m) }); addOne(c, m) }
  );
  ()
}

@cfg(target = "dotnet")
func checkGuardCatches(): Unit {
  checkGuardCatchesBody()
}

@cfg(target = "jvm")
func checkGuardCatches(): Unit {
  checkGuardCatchesBody()
}

@cfg(target = "native")
func checkGuardCatches(): Unit {
}

func checkGuardCatchesBody(): Unit {
  val c = newCounter()
  runGuarded({ -> panic("boom from work") }, { msg -> c.text = msg })
  assertTrue(c.text.contains("boom from work"), "runGuarded hands the panic message to onFailure")
  runGuarded({ -> c.n = 5 }, { msg -> c.n = 99 })
  assertEqualInt(c.n, 5, "a clean run does not call onFailure")
}

@cfg(target = "dotnet")
func checkPanickingTaskStillJoins(): Unit {
  checkPanickingTaskStillJoinsBody()
}

@cfg(target = "jvm")
func checkPanickingTaskStillJoins(): Unit {
  checkPanickingTaskStillJoinsBody()
}

@cfg(target = "native")
func checkPanickingTaskStillJoins(): Unit {
}

func checkPanickingTaskStillJoinsBody(): Unit {
  val set = newWorkerSet()
  val _ = workerAdd(set, { -> panic("worker fails on purpose") })
  workerJoinAll(set)
  releaseWorkerSet(set)
  assertTrue(true, "workerJoinAll returned although a worker panicked")
}

test "startTask runs its work on another thread" {
  val s = newSem(0)
  val c = newCounter()
  startTask({ -> c.n = 42; semPost(s) })
  semWait(s)
  assertEqualInt(c.n, 42, "the task ran and its write is visible after the semaphore")
  releaseSem(s)
}

test "many startTask closures handed over from a returned frame all run" {
  val s = newSem(0)
  startMany(s, 300)
  var i = 0
  while i < 300 {
    semWait(s)
    i = i + 1
  }
  assertFalse(semTryWait(s), "exactly one credit per task")
  releaseSem(s)
}

test "a mutex gives mutual exclusion across threads" {
  val m = newMutex()
  val c = newCounter()
  val set = newWorkerSet()
  val started = startWorkers(set, c, m, 8, 2000)
  assertEqualInt(started, 8, "every worker started")
  workerJoinAll(set)
  assertEqualInt(c.n, 16000, "no increment was lost")
  releaseWorkerSet(set)
  releaseMutex(m)
}

test "a mutex is reentrant" {
  val m = newMutex()
  val c = newCounter()
  lock(m)
  lock(m)
  c.n = 1
  unlock(m)
  unlock(m)
  val s = newSem(0)
  startTask({ -> lock(m); c.n = 2; unlock(m); semPost(s) })
  semWait(s)
  assertEqualInt(c.n, 2, "after both unlocks another thread can take the lock")
  releaseSem(s)
  releaseMutex(m)
}

test "a semaphore counts credits and semTryWait never blocks" {
  val s = newSem(2)
  assertTrue(semTryWait(s), "first initial credit")
  assertTrue(semTryWait(s), "second initial credit")
  assertFalse(semTryWait(s), "none left")
  semPost(s)
  semPost(s)
  semWait(s)
  assertTrue(semTryWait(s), "two posts gave two credits")
  assertFalse(semTryWait(s), "and no more")
  releaseSem(s)
}

test "a semaphore wait is woken by a later post from another thread" {
  val s = newSem(0)
  val started = Time.monotonicNanos()
  postAfter(s, 100)
  semWait(s)
  val elapsedMs = (Time.monotonicNanos() - started) / 1000000i64
  assertTrue(elapsedMs >= 80i64, "the wait blocked until the post")
  releaseSem(s)
}

test "a post made before the wait is not lost" {
  val s = newSem(0)
  semPost(s)
  semWait(s)
  assertFalse(semTryWait(s), "the one credit was consumed")
  releaseSem(s)
}

test "workerJoinAll waits for slow tasks and tasks they add" {
  val set = newWorkerSet()
  val c = newCounter()
  val m = newMutex()
  spawnNested(set, c, m)
  workerJoinAll(set)
  assertEqualInt(c.n, 2, "the task and the task it added both finished before the join returned")
  releaseWorkerSet(set)
  releaseMutex(m)
}

test "workerJoinAll on an empty set returns and the set is reusable" {
  val set = newWorkerSet()
  workerJoinAll(set)
  val c = newCounter()
  val m = newMutex()
  var round = 0
  while round < 3 {
    val _ = workerAdd(set, { -> addOne(c, m) })
    workerJoinAll(set)
    round = round + 1
  }
  assertEqualInt(c.n, 3, "each round's task finished before its join returned")
  releaseWorkerSet(set)
  releaseMutex(m)
}

test "runGuarded runs the work and ensureThreadCapacity is harmless" {
  ensureThreadCapacity()
  val c = newCounter()
  runGuarded({ -> c.n = 7 }, { msg -> c.n = 99 })
  assertEqualInt(c.n, 7, "the work ran")
}

test "runGuarded reports a panic to onFailure where the target can catch one" {
  checkGuardCatches()
}

test "a worker that panicked still counts as joined" {
  checkPanickingTaskStillJoins()
}
