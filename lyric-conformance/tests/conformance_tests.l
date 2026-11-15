//! tests/conformance_tests.l — runs each library's conformance suite against
//! its in-tree backend, so a backend cannot drift from what the interface
//! says.  Every case here runs on `dotnet`, the JVM and native: none of them
//! needs a panic to be caught.
//!
//! The last test runs a suite against a deliberately broken implementation: a
//! suite that cannot fail proves nothing.  The cases that need a caught panic
//! (a backend that panics, `requireConformance` failing its caller) and the
//! mocks' own conformance are in `lyric-testing/tests/conformance_tests.l`.
@test_module
package Testing.Conformance.SelfTests

import Std.Core
import Std.Collections
import Std.Uuid as Uuid
import Testing.Conformance
import Testing.Conformance.Cache as CacheConformance
import Testing.Conformance.Flags as FlagsConformance
import Testing.Conformance.Session as SessionConformance
import Testing.Conformance.Mq as MqConformance
import Testing.Conformance.Storage as StorageConformance
import Testing.Conformance.Jobs as JobsConformance
import Cache
import Flags
import Session
import Mq
import Storage
import Jobs
import Std.Testing

// ─── Cache ───────────────────────────────────────────────────────────────────
val cacheClock: Cache.ManualClock = Cache.manualClock(0i64)

func advanceCacheClock(seconds: in Int): Unit {
  cacheClock.millis = cacheClock.millis + seconds.toLong() * 1000i64
}

func makeInProcessCache(): Cache.CacheStore {
  val s: Cache.CacheStore = Cache.inProcessWithClock(cacheClock)
  return s
}

test "InProcessCacheStore conforms to CacheStore" {
  requireConformance(CacheConformance.run({ -> makeInProcessCache() }, { s -> advanceCacheClock(s) }))
}

// ─── Flags ───────────────────────────────────────────────────────────────────
func makeInProcessFlags(entries: in slice[Flags.FlagEntry]): Flags.FlagStore {
  val s: Flags.FlagStore = Flags.fromEntries(entries)
  return s
}

test "InProcessFlagStore conforms to FlagStore" {
  requireConformance(FlagsConformance.run({ entries -> makeInProcessFlags(entries) }))
}

// ─── Session ─────────────────────────────────────────────────────────────────
func makeInProcessSessions(): Session.SessionStore {
  val s: Session.SessionStore = Session.inMemory()
  return s
}

test "InProcessSessionStore conforms to SessionStore" {
  requireConformance(SessionConformance.run({ -> makeInProcessSessions() }))
}

// ─── Mq ──────────────────────────────────────────────────────────────────────
func makeInMemoryQueue(): MqConformance.QueueEnds {
  val queue = unwrapResult(Mq.connectTo("inmemory://conformance", "q-" + Uuid.uuidToString(Uuid.newUuid())))
  val publisher: Mq.MessageQueue = queue
  val consumer: Mq.QueueConsumer = queue
  return MqConformance.QueueEnds(publisher = publisher, consumer = consumer)
}

func makeDeadLetterStore(maxEntries: in Int): Mq.DeadLetterStore {
  val s: Mq.DeadLetterStore = Mq.inProcessDeadLetterStore(maxEntries)
  return s
}

test "the in-memory broker conforms to MessageQueue and QueueConsumer" {
  requireConformance(MqConformance.runQueue({ -> makeInMemoryQueue() }))
}

test "InProcessDeadLetterStore conforms to DeadLetterStore" {
  requireConformance(MqConformance.runDeadLetterStore({ n -> makeDeadLetterStore(n) }))
}

// ─── Storage ─────────────────────────────────────────────────────────────────
func makeLocalBucket(): Storage.StorageBucket {
  val name = "conformance-" + Uuid.uuidToString(Uuid.newUuid())
  return unwrapResult(Storage.connectLocal("/tmp/lyric-storage-conformance", name))
}

test "the local filesystem bucket conforms to StorageBucket" {
  requireConformance(StorageConformance.run({ -> makeLocalBucket() }))
}

// ─── Jobs ────────────────────────────────────────────────────────────────────
func makeInProcessJobs(): Jobs.JobScheduler {
  val s: Jobs.JobScheduler = Jobs.inProcess()
  return s
}

test "InProcessJobScheduler conforms to JobScheduler" {
  requireConformance(JobsConformance.run({ -> makeInProcessJobs() }))
}

// ─── The suites can fail ─────────────────────────────────────────────────────
ref record ForgetfulCache {
  var calls: Int
}

impl Cache.CacheStore for ForgetfulCache {
  func get(key: in String): Option[String] {
    return None
  }
  func set(key: in String, value: in String, ttlSeconds: in Int): Unit {
    self.calls = self.calls + 1
  }
  func delete(key: in String): Unit {
    self.calls = self.calls + 1
  }
  func clear(): Unit {
    self.calls = self.calls + 1
  }
}

func makeForgetful(): Cache.CacheStore {
  val s: Cache.CacheStore = ForgetfulCache(calls = 0)
  return s
}

test "the cache suite reports a store that forgets what it was given" {
  val checks = CacheConformance.run({ -> makeForgetful() }, { s -> advanceCacheClock(s) })
  Std.Testing.assertTrue(failures(checks).length > 0, "a forgetful store must fail the suite")
  Std.Testing.assertTrue(caseCount(checks) > 5, "the cases after the first failure still ran")
  Std.Testing.assertTrue(summary(checks).length > 0, "the summary names the failures")
}
