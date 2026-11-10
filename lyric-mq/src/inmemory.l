//! Mq.InMemory — the in-process reference broker, pure Lyric on every target.
//!
//! Each `connect` opens an independent queue (a handle into a process-wide
//! registry).  Publishing appends to the queue; consuming moves the oldest
//! message to the in-flight set and counts the delivery; `ack` settles it,
//! and `nack` with `requeue = true` puts it back at the tail for redelivery
//! (RabbitMQ's `basic.nack(requeue)` semantics).  A `nack` without requeue
//! drops the message: there is no broker-side dead-letter queue, applications
//! dead-letter through `Mq.DeadLetterStore`.
//!
//! The queue and the registry are protected types, so publishers, consumers
//! and `connect`/`close` may run on any threads.  `consume` waits by polling
//! the queue every few milliseconds until its timeout, so it never holds a
//! lock while it waits.
//!
//! Wire format for a delivered message, shared with `Mq.messageFromJson`:
//!   {"id":"...","body":"...","headers":[...],"deliveryCount":N}
@runtime_checked
@io
package Mq.InMemory

import Std.Core
import Std.Collections
import Std.Time
import Std.Json

record StoredMessage {
  id: String
  body: String
  headersJson: String
  deliveryCount: Int
}

protected type BrokerQueue {
  var pending: List[StoredMessage] = newList()
  var inFlight: Map[String, StoredMessage] = newMap()
  invariant: pending.count >= 0
  entry publish(m: in StoredMessage) {
    pending.add(m)
  }
  // The oldest pending message, as it was before this delivery; the in-flight
  // copy carries the incremented count a redelivery reports.
  entry poll(): Option[StoredMessage] {
    if pending.count == 0 {
      return None
    }
    val m = pending[0]
    pending.removeAt(0)
    inFlight[m.id] = StoredMessage(
      id = m.id,
      body = m.body,
      headersJson = m.headersJson,
      deliveryCount = m.deliveryCount + 1
    )
    return Some(value = m)
  }
  entry settle(id: in String, requeue: in Bool) {
    if inFlight.containsKey(id) {
      val m = inFlight[id]
      inFlight.remove(id)
      if requeue {
        pending.add(m)
      }
    }
  }
}

protected type BrokerRegistry {
  var queues: Map[Int, BrokerQueue] = newMap()
  var next: Int = 0
  entry open(): Int {
    next = next + 1
    queues[next] = BrokerQueue()
    return next
  }
  entry find(handle: in Int): Option[BrokerQueue] {
    if queues.containsKey(handle) {
      return Some(value = queues[handle])
    }
    return None
  }
  entry drop(handle: in Int) {
    val _ = queues.remove(handle)
  }
}

func newRegistry(): BrokerRegistry {
  return BrokerRegistry()
}

val registry: BrokerRegistry = newRegistry()

func unknownHandle(handle: in Int): String {
  return "unknown queue handle " + handle.toString()
}

func render(m: in StoredMessage): String {
  val headers = if m.headersJson.length == 0 { "[]" } else { m.headersJson }
  return "{\"id\":" + encodeString(m.id) + ",\"body\":" + encodeString(m.body) + ",\"headers\":" + headers +
    ",\"deliveryCount\":" +
    m.deliveryCount.toString() +
    "}"
}

/// Open a new, empty queue and return its handle.  `url` is accepted for
/// parity with a networked broker's connect and is not interpreted.
pub func connect(url: in String, queueName: in String): Result[Int, String]
  requires: queueName.length > 0
{
  return Ok(registry.open())
}

pub func publish(handle: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  match registry.find(handle) {
    case None -> return Err(unknownHandle(handle))
    case Some(q) -> {
      q.publish(StoredMessage(id = messageId, body = body, headersJson = headersJson, deliveryCount = 0))
      return Ok(())
    }
  }
}

/// The next message as wire JSON, or `""` when none arrived within
/// `timeoutMs` (0 polls once without waiting).
pub func consume(handle: in Int, timeoutMs: in Int): Result[String, String]
  requires: timeoutMs >= 0
{
  match registry.find(handle) {
    case None -> return Err(unknownHandle(handle))
    case Some(q) -> {
      var remaining = timeoutMs
      var next = q.poll()
      while not isSome(next) and remaining > 0 {
        val wait = if remaining > 5 { 5 } else { remaining }
        sleepMillis(wait)
        remaining = remaining - wait
        next = q.poll()
      }
      match next {
        case Some(m) -> return Ok(render(m))
        case None -> return Ok("")
      }
    }
  }
}

pub func ack(handle: in Int, deliveryTag: in String): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  return settle(handle, deliveryTag, false)
}

pub func nack(handle: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String]
  requires: deliveryTag.length > 0
{
  return settle(handle, deliveryTag, requeue)
}

func settle(handle: in Int, tag: in String, requeue: in Bool): Result[Unit, String] {
  match registry.find(handle) {
    case None -> return Err(unknownHandle(handle))
    case Some(q) -> {
      q.settle(tag, requeue)
      return Ok(())
    }
  }
}

pub func close(handle: in Int): Unit {
  registry.drop(handle)
}
