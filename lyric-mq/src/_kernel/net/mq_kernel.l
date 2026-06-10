//! Mq.Kernel.Net — .NET kernel boundary for message broker drivers.
//!
//! Phase 5 of #733: in-memory queue backend functional via pure Lyric
//! ConcurrentQueue / ConcurrentDictionary state.  Replaces Lyric.Mq.InMemoryHost
//! F# shim.  The four broker drivers (RabbitMQ, Azure Service Bus, AWSSDK.SQS,
//! Confluent.Kafka) remain declarative-only — their bindings return a clear "not
//! yet implemented" error until broker-specific Testcontainers infrastructure
//! lands (#779 follow-up).
//!
//! All drivers use an integer queueId handle issued at connect time.  The
//! in-memory backend maintains a per-process ConcurrentQueue<Message> for
//! pending messages and a ConcurrentDictionary<String, Message> for in-flight
//! tracking, mirroring RabbitMQ's basic.nack(requeue) semantics.
//!
//! publishBatch was removed from the kernel boundary (#1022): the public
//! Mq.publishBatch wrapper loops over publish at the Lyric level.
//!
//! Wire format for messages returned by consume:
//!   JSON object: {"id":"...","body":"...","headers":[],"deliveryCount":N}
//!   Empty string "" signals a timeout (no message available).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
package Mq.Kernel.Net

import Std.Core
import Std.Time
import Std.Char

// ─── ConcurrentDictionary externs ────────────────────────────────────────────
extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryRemove")
func cdTryRemove[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

// ─── ConcurrentQueue extern ───────────────────────────────────────────────────
extern type ConcurrentQueue[T] = "System.Collections.Concurrent.ConcurrentQueue`1"

@externTarget("System.Collections.Concurrent.ConcurrentQueue`1..ctor")
func newConcurrentQueue[T](): ConcurrentQueue[T] = ()

@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.Enqueue")
func cqEnqueue[T](q: in ConcurrentQueue[T], item: in T): Unit = ()

@externTarget("System.Collections.Concurrent.ConcurrentQueue`1.TryDequeue")
func cqTryDequeue[T](q: in ConcurrentQueue[T], result: out T): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// ─── Message and queue state ──────────────────────────────────────────────────
record Message {
  id: String
  body: String
  headersJson: String
  var deliveryCount: Int = 0
}

record InMemoryQueue {
  name: String
  pending: ConcurrentQueue[Message]
  inFlight: ConcurrentDict[String, Message]
}

record MqHandleCounter {
  var next: Int = 0
}

val mqHandleCounter: MqHandleCounter = MqHandleCounter()

val queueRegistry: ConcurrentDict[Int, InMemoryQueue] = newConcurrentDict()

// Minimal JSON string escaper for message rendering.
func mqJsonStr(s: in String): String {
  var r = "\""
  var i = 0
  while i < s.length {
    val code = toInt(s[i])
    if code == 34 {
      r = r + "\\\""
    } else if code == 92 {
      r = r + "\\\\"
    } else if code == 10 {
      r = r + "\\n"
    } else if code == 13 {
      r = r + "\\r"
    } else if code == 9 {
      r = r + "\\t"
    } else {
      r = r + s[i].toString()
    }
    i = i + 1
  }
  r + "\""
}

func renderMessage(m: in Message): String {
  val headers = if m.headersJson.length == 0 { "[]" } else { m.headersJson }
  "{\"id\":" + mqJsonStr(m.id) + ",\"body\":" + mqJsonStr(m.body) + ",\"headers\":" + headers + ",\"deliveryCount\":" +
    m.deliveryCount.toString() +
    "}"
}

// ─── In-memory backend (Phase 5 functional path) ─────────────────────────────
@cfg(feature = "inmemory")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length >= 0
  requires: queueName.length > 0
{
  monitorEnter(mqHandleCounter)
  defer {
    monitorExit(mqHandleCounter)
  }
  mqHandleCounter.next = mqHandleCounter.next + 1
  val handle = mqHandleCounter.next
  val q = InMemoryQueue(name = queueName, pending = newConcurrentQueue(), inFlight = newConcurrentDict())
  val _ = cdTryAdd(queueRegistry, handle, q)
  Ok(handle)
}

@cfg(feature = "inmemory")
pub func publish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  var q: InMemoryQueue = default()
  if not cdTryGetValue(queueRegistry, queueId, q) {
    return Err("unknown queue handle " + queueId.toString())
  }
  val m = Message(id = messageId, body = body, headersJson = headersJson)
  cqEnqueue(q.pending, m)
  Ok(())
}

@cfg(feature = "inmemory")
pub func consume(queueId: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs > 0
{
  var q: InMemoryQueue = default()
  if not cdTryGetValue(queueRegistry, queueId, q) {
    return Err("unknown queue handle " + queueId.toString())
  }
  var remaining = timeoutMs
  var found = false
  var msg: Message = default()
  while not found and remaining > 0 {
    if cqTryDequeue(q.pending, msg) {
      found = true
    } else {
      val wait = if remaining > 25 { 25 } else { remaining }
      sleepMillis(wait)
      remaining = remaining - wait
    }
  }
  if found {
    msg.deliveryCount = msg.deliveryCount + 1
    val _ = cdTryAdd(q.inFlight, msg.id, msg)
    Ok(renderMessage(msg))
  } else {
    Ok("")
  }
}

@cfg(feature = "inmemory")
pub func ack(queueId: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  var q: InMemoryQueue = default()
  if not cdTryGetValue(queueRegistry, queueId, q) {
    return Err("unknown queue handle " + queueId.toString())
  }
  var m: Message = default()
  val _ = cdTryRemove(q.inFlight, deliveryTag, m)
  Ok(())
}

@cfg(feature = "inmemory")
pub func nack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  var q: InMemoryQueue = default()
  if not cdTryGetValue(queueRegistry, queueId, q) {
    return Err("unknown queue handle " + queueId.toString())
  }
  var m: Message = default()
  if cdTryRemove(q.inFlight, deliveryTag, m) {
    if requeue {
      cqEnqueue(q.pending, m)
    }
  }
  Ok(())
}

@cfg(feature = "inmemory")
pub func close(queueId: in Int): Unit {
  var q: InMemoryQueue = default()
  val _ = cdTryRemove(queueRegistry, queueId, q)
}

// ─── Broker driver placeholders (#733 follow-ups) ────────────────────────────
@cfg(feature = "rabbitmq")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  Err("lyric-mq: RabbitMQ backend not yet implemented (Phase 5 follow-up of #733)")
}

@cfg(feature = "azureservicebus")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  Err("lyric-mq: Azure Service Bus backend not yet implemented (Phase 5 follow-up of #733)")
}

@cfg(feature = "sqs")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  Err("lyric-mq: AWSSDK.SQS backend not yet implemented (Phase 5 follow-up of #733)")
}

@cfg(feature = "kafka")
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: url.length > 0
  requires: queueName.length > 0
{
  Err("lyric-mq: Confluent.Kafka backend not yet implemented (Phase 5 follow-up of #733)")
}
