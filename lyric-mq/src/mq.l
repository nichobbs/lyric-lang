// Mq — transport-agnostic message queue library for Lyric.
//
// Stability: @stable(since="0.1") — the `MessageQueue` /
// `QueueConsumer` / `DeadLetterStore` interfaces, the
// `Idempotent` / `DeadLetter` aspect templates, and the built-in
// `NativeQueue` implementation are covered by the SemVer guarantee
// at the surface level.  Individual broker feature flags
// (rabbitmq / azureservicebus / sqs / kafka) carry their own
// experimental envelope until each has end-to-end CI coverage.
//
// `MessageQueue` and `QueueConsumer` are the public interfaces; implement
// them to plug in any broker.  `NativeQueue` is the built-in broker-backed
// implementation driven through the platform kernel.
//
// Supported brokers (feature-gated via lyric.toml [features]):
//   rabbitmq        — RabbitMQ via AMQP 0-9-1
//   azureservicebus — Azure Service Bus
//   sqs             — Amazon SQS
//   kafka           — Apache Kafka
//
// Usage:
//
//   import Mq
//   import Std.Core
//
//   val queue = Mq.connect()?
//   Mq.publish(queue, Message(
//     id           = "msg-001",
//     body         = "{\"event\":\"order.placed\",\"orderId\":42}",
//     headers      = [MessageHeader(key = "content-type", value = "application/json")],
//     deliveryCount = 0))?
//
//   Mq.consume(queue, 5000, func(msg: in Message): Result[Unit, String] {
//     println("received: " + msg.id)
//     Ok(())
//   })?
//
// Runtime config env vars (LYRIC_CONFIG_MQ_CONNECTION_*):
//   LYRIC_CONFIG_MQ_CONNECTION_URL                 — broker URL (required)
//   LYRIC_CONFIG_MQ_CONNECTION_QUEUENAME           — queue / topic name (required)
//   LYRIC_CONFIG_MQ_CONNECTION_ACKMODE             — "Auto" or "Manual" (default: Auto)
//   LYRIC_CONFIG_MQ_CONNECTION_MAXDELIVERYCOUNT    — redelivery limit (default: 5)
//   LYRIC_CONFIG_MQ_CONNECTION_VISIBILITYTIMEOUTMS — SQS/ASB visibility (default: 30000)
//
// See docs/03-decision-log.md D056 and lyric-mq/README.md.

@runtime_checked
package Mq

import Std.Core
import Std.Collections
import Std.String
import Std.Json
import Std.Iter
import Std.Parse
import Std.Environment as Env

// ─── Wire types ───────────────────────────────────────────────────────────────

/// A single message metadata pair.
@stable(since="0.1")
pub record MessageHeader {
  key:   String
  value: String
}

/// A message as delivered from or sent to the broker.
///
/// `deliveryCount` tracks how many times this message has been attempted;
/// starts at 0 for the first delivery.  Brokers increment it on each
/// redelivery.  Use it with `Connection.maxDeliveryCount` to detect
/// poison messages and route them to a dead-letter store.
@stable(since="0.1")
pub record Message {
  id:            String
  body:          String
  headers:       slice[MessageHeader]
  deliveryCount: Int
}

/// An entry in the dead-letter store.
@stable(since="0.1")
pub record DeadLetterEntry {
  message:  Message
  reason:   String
  failedAt: Long    // epoch milliseconds
}

/// Acknowledgement mode for received messages.
///
/// `Auto` — the broker considers the message acknowledged as soon as the
///          consumer callback returns without error.
/// `Manual` — the consumer must call `Mq.ack` or `Mq.nack` explicitly.
@stable(since="0.1")
pub enum AckMode {
  case Auto
  case Manual
}

// ─── Publish interface ────────────────────────────────────────────────────────

/// Interface for publishing messages to a queue or topic.
@stable(since="0.1")
pub interface MessageQueue {
  /// Publish a single message.  Returns Ok(()) on broker acceptance.
  func publish(message: in Message): Result[Unit, String]
    requires: message.id.length > 0
    requires: message.body.length >= 0

  /// Publish a batch of messages.
  ///
  /// Atomicity is broker-dependent: implementations that have native
  /// batch transactions (e.g. RabbitMQ confirms, Kafka transactional
  /// producer) deliver all-or-nothing.  The default `NativeQueue`
  /// implementation iterates sequentially and returns the first
  /// failure — messages already accepted by the broker before that
  /// failure remain in the queue, so callers that need strict
  /// all-or-nothing semantics must use a broker that supports them or
  /// build idempotency at the consumer (#1046).
  func publishBatch(messages: in slice[Message]): Result[Unit, String]
    requires: messages.length > 0
}

// ─── Consumer interface ───────────────────────────────────────────────────────

/// Interface for consuming messages from a queue or subscription.
@stable(since="0.1")
pub interface QueueConsumer {
  /// Block for up to `timeoutMs` milliseconds waiting for the next message,
  /// then invoke `handler`.  Returns Ok(()) when the handler completes
  /// successfully, or Err when the handler fails or no message arrived within
  /// the timeout (Err("timeout")).  Pass 0 to poll without blocking.
  func consume(
    timeoutMs: in Int,
    handler:   (Message) -> Result[Unit, String]
  ): Result[Unit, String]
    requires: timeoutMs >= 0

  /// Acknowledge that a message was processed successfully.
  /// No-op when ackMode is Auto.
  func ack(messageId: in String): Result[Unit, String]
    requires: messageId.length > 0

  /// Negatively acknowledge a message.  When `requeue` is true the broker
  /// redelivers the message; when false it routes to the broker dead-letter
  /// queue (if configured).
  func nack(messageId: in String, requeue: in Bool): Result[Unit, String]
    requires: messageId.length > 0

  /// Close the consumer and release the underlying channel/connection.
  func close(): Unit
}

// ─── Dead-letter store interface ─────────────────────────────────────────────

/// Storage for messages that exceeded their delivery limit or were explicitly
/// dead-lettered by the application.
@stable(since="0.1")
pub interface DeadLetterStore {
  /// Append an entry.  Does not deduplicate by message id.
  func append(dlEntry: in DeadLetterEntry): Unit

  /// Return all dead-letter entries in insertion order.
  func list(): slice[DeadLetterEntry]

  /// Return the number of entries in the store.
  func count(): Int
}

// ─── In-process dead-letter store ────────────────────────────────────────────

/// In-memory dead-letter store; useful for testing and single-process apps.
///
/// Entries are held in insertion order.  When `maxEntries` is reached the
/// oldest entry is discarded to make room, preserving the configured capacity.
@stable(since="0.1")
pub record InProcessDeadLetterStore {
  var entries:    slice[DeadLetterEntry]
  maxEntries: Int
}

impl DeadLetterStore for InProcessDeadLetterStore {
  func append(dlEntry: in DeadLetterEntry): Unit {
    if self.entries.length < self.maxEntries {
      self.entries = self.entries + [dlEntry]
    } else {
      var trimmed: slice[DeadLetterEntry] = []
      var i: Int = 1
      while i < self.entries.length {
        trimmed = trimmed + [self.entries[i]]
        i = i + 1
      }
      self.entries = trimmed + [dlEntry]
    }
  }

  func list(): slice[DeadLetterEntry] {
    return self.entries
  }

  func count(): Int {
    return self.entries.length
  }
}

// ─── Native queue (broker-backed) ────────────────────────────────────────────

/// Broker-backed queue handle.  Obtain one via `Mq.connect()`.
///
/// Implements both `MessageQueue` and `QueueConsumer` so a single record
/// can be used for publish/consume on the same queue.
@stable(since="0.1")
pub record NativeQueue {
  queueId: Int    // opaque handle issued by the kernel
}

impl MessageQueue for NativeQueue {
  func publish(message: in Message): Result[Unit, String]
    requires: message.id.length > 0
  {
    val headersJson = headersToJson(message.headers)
    return mqKernelPublish(self.queueId, message.id, message.body, headersJson)
  }

  func publishBatch(messages: in slice[Message]): Result[Unit, String]
    requires: messages.length > 0
  {
    var i: Int = 0
    while i < messages.length {
      val m = messages[i]
      val hj = headersToJson(m.headers)
      match mqKernelPublish(self.queueId, m.id, m.body, hj) {
        case Err(e) -> return Err(e)
        case Ok(_)  -> ()
      }
      i = i + 1
    }
    return Ok(())
  }
}

impl QueueConsumer for NativeQueue {
  func consume(
    timeoutMs: in Int,
    handler:   (Message) -> Result[Unit, String]
  ): Result[Unit, String]
    requires: timeoutMs >= 0
  {
    match mqKernelConsume(self.queueId, timeoutMs) {
      case Err(e)       -> Err(e)
      case Ok(msgJson)  -> {
        // Empty string signals no message was available within the timeout
        // (including an immediate poll when timeoutMs == 0).
        if msgJson == "" {
          return Err("timeout")
        }
        val msg = messageFromJson(msgJson)
        return handler(msg)
      }
    }
  }

  func ack(messageId: in String): Result[Unit, String]
    requires: messageId.length > 0
  {
    return mqKernelAck(self.queueId, messageId)
  }

  func nack(messageId: in String, requeue: in Bool): Result[Unit, String]
    requires: messageId.length > 0
  {
    return mqKernelNack(self.queueId, messageId, requeue)
  }

  func close(): Unit {
    mqKernelClose(self.queueId)
  }
}

// ─── Config (env-var backed) ──────────────────────────────────────────────────
//
// Config blocks are declared here for documentation purposes.
// Field values are read from environment variables at connection time.
// LYRIC_CONFIG_MQ_CONNECTION_URL           — broker URL (required)
// LYRIC_CONFIG_MQ_CONNECTION_QUEUENAME     — queue / topic name (required)
// LYRIC_CONFIG_MQ_DEADLETTER_ENABLED       — "true"/"false" (default: true)
// LYRIC_CONFIG_MQ_DEADLETTER_MAXENTRIES    — integer (default: 10000)

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open a broker connection using the configured URL and queue name.
/// Returns a `NativeQueue` that implements both `MessageQueue` and
/// `QueueConsumer`.
@stable(since="0.1")
pub func connect(): Result[NativeQueue, String] {
  val url       = Env.getVarOrDefault("LYRIC_CONFIG_MQ_CONNECTION_URL", "")
  val queueName = Env.getVarOrDefault("LYRIC_CONFIG_MQ_CONNECTION_QUEUENAME", "")
  match mqKernelConnect(url, queueName) {
    case Ok(queueId) -> Ok(NativeQueue(queueId = queueId))
    case Err(msg)    -> Err(msg)
  }
}

/// Open a broker connection and pair it with an in-process dead-letter store.
/// Returns (NativeQueue, InProcessDeadLetterStore).
@stable(since="0.1")
pub func connectWithDeadLetter(): Result[(NativeQueue, InProcessDeadLetterStore), String] {
  match connect() {
    case Err(msg)  -> Err(msg)
    case Ok(queue) -> {
      val maxEntriesStr = Env.getVarOrDefault("LYRIC_CONFIG_MQ_DEADLETTER_MAXENTRIES", "10000")
      val maxEntries    = match parseOptInt(maxEntriesStr) { case Some(n) -> n  case None -> 10000 }
      val dlStore = InProcessDeadLetterStore(
        entries    = [],
        maxEntries = maxEntries)
      Ok((queue, dlStore))
    }
  }
}

/// Create a standalone in-process dead-letter store with an explicit capacity.
@stable(since="0.1")
pub func inProcessDeadLetterStore(maxEntries: in Int): InProcessDeadLetterStore
  requires: maxEntries >= 1
{
  return InProcessDeadLetterStore(entries = [], maxEntries = maxEntries)
}

// ─── Convenience wrappers ─────────────────────────────────────────────────────

/// Publish a single message to `queue`.
@stable(since="0.1")
pub func publish(queue: in MessageQueue, message: in Message): Result[Unit, String]
  requires: message.id.length > 0
{
  return queue.publish(message)
}

/// Publish a batch of messages to `queue`.
@stable(since="0.1")
pub func publishBatch(queue: in MessageQueue, messages: in slice[Message]): Result[Unit, String]
  requires: messages.length > 0
{
  return queue.publishBatch(messages)
}

/// Block for up to `timeoutMs` milliseconds, consume one message, and invoke
/// `handler`.  Pass 0 to poll without blocking.
@stable(since="0.1")
pub func consume(
  consumer:  in QueueConsumer,
  timeoutMs: in Int,
  handler:   (Message) -> Result[Unit, String]
): Result[Unit, String]
  requires: timeoutMs >= 0
{
  return consumer.consume(timeoutMs, handler)
}

/// Acknowledge a successfully-processed message.
@stable(since="0.1")
pub func ack(consumer: in QueueConsumer, messageId: in String): Result[Unit, String]
  requires: messageId.length > 0
{
  return consumer.ack(messageId)
}

/// Negatively acknowledge a message.
@stable(since="0.1")
pub func nack(consumer: in QueueConsumer, messageId: in String, requeue: in Bool): Result[Unit, String]
  requires: messageId.length > 0
{
  return consumer.nack(messageId, requeue)
}

// ─── Platform dispatch helpers (private) ─────────────────────────────────────
// These are axiom-backed unconditional functions that dispatch to the active
// broker kernel at runtime. Feature selection happens at kernel initialization.

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelConnect(url: in String, queueName: in String): Result[Int, String] = Err("no broker configured")

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelPublish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] = Ok(())

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelConsume(queueId: in Int, timeoutMs: in Int): Result[String, String] = Ok("")

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelAck(queueId: in Int, deliveryTag: in String): Result[Unit, String] = Ok(())

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelNack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] = Ok(())

@axiom("broker kernel dispatch — forwards to the active broker driver at runtime")
func mqKernelClose(queueId: in Int): Unit = ()

// ─── JSON serialisation helpers (private) ────────────────────────────────────

// Serialise a list of MessageHeader to a compact JSON array.
// Format: [{"key":"<k>","value":"<v>"},...]
func headersToJson(headers: in slice[MessageHeader]): String {
  if headers.length == 0 {
    return "[]"
  }
  var parts: slice[String] = []
  for h in headers {
    parts = concat(parts, ["{\"key\":\"" + jsonEscape(h.key) + "\",\"value\":\"" + jsonEscape(h.value) + "\"}"])
  }
  return "[" + join(",", parts) + "]"
}

// Deserialise a JSON object (produced by the kernel) back into a Message.
// The kernel emits the same format as messagesToJson above.
// `id` and `body` are extracted via Std.Json to correctly handle escaped
// characters in field values (fixes hand-rolled jsonExtractString truncation).
func messageFromJson(json: in String): Message {
  val doc  = parseJson(json)
  val root = rootElement(doc)
  val id = match tryGetProperty(root, "id") {
    case Some(v) -> getString(v)
    case None    -> ""
  }
  val body = match tryGetProperty(root, "body") {
    case Some(v) -> getString(v)
    case None    -> ""
  }
  val deliveryCount = jsonExtractInt(json, "deliveryCount")
  // Headers are conveyed in a nested JSON array; parse key/value pairs.
  val hdrsRaw = jsonExtractRaw(json, "headers")
  val headers = parseHeadersJson(hdrsRaw)
  return Message(id = id, body = body, headers = headers, deliveryCount = deliveryCount)
}

// Parse a JSON array of {key,value} objects into a list of MessageHeader.
func parseHeadersJson(json: in String): slice[MessageHeader] {
  if json == "[]" or json == "" {
    return []
  }
  var result: slice[MessageHeader] = []
  val doc    = parseJson(json)
  val root   = rootElement(doc)
  var en     = enumerateArray(root)
  while arrayMoveNext(en) {
    val obj = arrayCurrent(en)
    var key   = ""
    var value = ""
    match tryGetProperty(obj, "key") {
      case Some(v) -> { key = getString(v) }
      case None    -> ()
    }
    match tryGetProperty(obj, "value") {
      case Some(v) -> { value = getString(v) }
      case None    -> ()
    }
    result = concat(result, [MessageHeader(key = key, value = value)])
  }
  return result
}

// Extract an integer field value from a JSON object literal.
func jsonExtractInt(json: in String, field: in String): Int {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return 0 }
  val afterColon = start + needle.length
  // Skip whitespace.
  var i: Int = afterColon
  while i < json.length and json[i] == ' ' { i = i + 1 }
  var numStr: String = ""
  while i < json.length and json[i] != ',' and json[i] != '}' {
    numStr = numStr + json[i].toString()
    i = i + 1
  }
  match parseOptInt(numStr.trim()) {
    case Some(n) -> return n
    case None    -> return 0
  }
}

// Extract the raw JSON value for a field (for nested objects/arrays).
func jsonExtractRaw(json: in String, field: in String): String {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return "[]" }
  val afterColon = start + needle.length
  val q1 = json.indexOf("[", afterColon)
  if q1 < 0 { return "[]" }
  var depth: Int = 0
  var i: Int     = q1
  while i < json.length {
    val ch = json[i]
    if ch == '[' { depth = depth + 1 }
    else if ch == ']' {
      depth = depth - 1
      if depth == 0 { return json.substring(q1, i + 1) }
    }
    i = i + 1
  }
  return "[]"
}

// Escape special characters for JSON string embedding.
func jsonEscape(s: in String): String {
  var buf: String = ""
  var i:   Int    = 0
  while i < s.length {
    val ch = s[i]
    if ch == '"'       { buf = buf + "\\\"" }
    else if ch == '\\' { buf = buf + "\\\\" }
    else if ch == '\n' { buf = buf + "\\n"  }
    else if ch == '\r' { buf = buf + "\\r"  }
    else if ch == '\t' { buf = buf + "\\t"  }
    else               { buf = buf + ch.toString() }
    i = i + 1
  }
  return buf
}
