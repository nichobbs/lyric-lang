//! tests/conformance_tests.l — runs each library's conformance suite against
//! every in-tree backend, and against the mocks that implement the same
//! contract, so a backend or mock cannot drift from what the interface says.
//!
//! The negative tests at the end run each suite against a deliberately broken
//! implementation: a suite that cannot fail proves nothing.
@test_module
package Testing.ConformanceTests

import Std.Core
import Std.Collections
import Std.Uuid as Uuid
import Testing
import Testing.Conformance
import Testing.Conformance.Cache as CacheConformance
import Testing.Conformance.Flags as FlagsConformance
import Testing.Conformance.Session as SessionConformance
import Testing.Conformance.Mq as MqConformance
import Testing.Conformance.Storage as StorageConformance
import Testing.Conformance.Jobs as JobsConformance
import Testing.Conformance.Search as SearchConformance
import Cache
import Flags
import Session
import Mq
import Storage
import Jobs
import Search
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

func makeMockJobs(): Jobs.JobScheduler {
  val s: Jobs.JobScheduler = Testing.MockJobScheduler(specs = newList(), results = newMap(), counter = 0)
  return s
}

test "InProcessJobScheduler conforms to JobScheduler" {
  requireConformance(JobsConformance.run({ -> makeInProcessJobs() }))
}

test "MockJobScheduler conforms to JobScheduler" {
  requireConformance(JobsConformance.run({ -> makeMockJobs() }))
}

// ─── Search ──────────────────────────────────────────────────────────────────
func makeMockSearch(): Search.SearchClient {
  val s: Search.SearchClient = Testing.newMockSearchClient()
  return s
}

test "MockSearchClient conforms to SearchClient" {
  requireConformance(await SearchConformance.run({ -> makeMockSearch() }))
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

ref record PanickingCache {
  var calls: Int
}

impl Cache.CacheStore for PanickingCache {
  func get(key: in String): Option[String] {
    panic("backend exploded")
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

func makePanicking(): Cache.CacheStore {
  val s: Cache.CacheStore = PanickingCache(calls = 0)
  return s
}

test "the cache suite reports a store that forgets what it was given" {
  val checks = CacheConformance.run({ -> makeForgetful() }, { s -> advanceCacheClock(s) })
  Std.Testing.assertTrue(failures(checks).length > 0, "a forgetful store must fail the suite")
  Std.Testing.assertPanics("requireConformance fails the calling test", { -> requireConformance(checks) })
}

test "a panic inside a backend fails its case, not the whole run" {
  val checks = CacheConformance.run({ -> makePanicking() }, { s -> advanceCacheClock(s) })
  Std.Testing.assertTrue(failures(checks).length > 0, "a panicking store must fail the suite")
  Std.Testing.assertTrue(caseCount(checks) > 5, "the cases after the panic still ran")
}

test "an empty suite is not a pass" {
  val checks = newChecks("Empty")
  Std.Testing.assertPanics("no cases run", { -> requireConformance(checks) })
}

// ─── Mocks that carry behaviour ──────────────────────────────────────────────
test "MockJobScheduler lets a test drive a job to Succeeded and Failed" {
  val m = Testing.MockJobScheduler(specs = newList(), results = newMap(), counter = 0)
  val a = unwrapResult(Jobs.enqueue(m, "a", "{}"))
  val b = unwrapResult(Jobs.enqueue(m, "b", "{}"))
  Testing.completeJob(m, a, "done")
  Testing.failJob(m, b, "boom")
  Std.Testing.assertEqualInt(Testing.submittedCount(m), 2, "two submissions recorded")
  match Jobs.status(m, a) {
    case Ok(Jobs.JobStatus.Succeeded) -> ()
    case _ -> Std.Testing.assertTrue(false, "a should have succeeded")
  }
  match Jobs.status(m, b) {
    case Ok(Jobs.JobStatus.Failed) -> ()
    case _ -> Std.Testing.assertTrue(false, "b should have failed")
  }
}

test "MockQueueConsumer delivers its script and records settlements" {
  val c = Testing.newMockQueueConsumer()
  Testing.deliver(c, Mq.Message(id = "m1", body = "x", headers = [], deliveryCount = 0))
  val consumer: Mq.QueueConsumer = c
  val r = consumer.consume(0, { m -> remember(m) })
  Std.Testing.assertTrue(isOk(r), "the scripted message is delivered")
  val _ = consumer.ack("m1")
  val _ = consumer.nack("m2", true)
  Std.Testing.assertEqualInt(Testing.ackedIds(c).length, 1, "one ack recorded")
  Std.Testing.assertEqualInt(Testing.nackedIds(c).length, 1, "one nack recorded")
  match consumer.consume(0, { m -> remember(m) }) {
    case Err(e) -> Std.Testing.assertEqual(e, "timeout", "an exhausted script times out")
    case Ok(_) -> Std.Testing.assertTrue(false, "nothing left to deliver")
  }
}

func remember(m: in Mq.Message): Result[Unit, String] {
  return Ok(())
}
