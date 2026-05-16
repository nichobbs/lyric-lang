/// Mq — transport-agnostic message queue library for Lyric.
///
/// `MessageQueue` and `QueueConsumer` are the public interfaces; implement
/// them to plug in any broker.  `NativeQueue` is the built-in broker-backed
/// implementation driven through the platform kernel.
///
/// Supported brokers (feature-gated via lyric.toml [features]):
///   rabbitmq        — RabbitMQ via AMQP 0-9-1
///   azureservicebus — Azure Service Bus
///   sqs             — Amazon SQS
///   kafka           — Apache Kafka
///
/// Usage:
///
///   import Mq
///   import Std.Core
///
///   val queue = Mq.connect()?
///   Mq.publish(queue, Message(
///     id           = "msg-001",
///     body         = "{\"event\":\"order.placed\",\"orderId\":42}",
///     headers      = [MessageHeader(key = "content-type", value = "application/json")],
///     deliveryCount = 0))?
///
///   Mq.consume(queue, 5000, func(msg: in Message): Result[Unit, String] {
///     println("received: " + msg.id)
///     Ok(())
///   })?
///
/// Runtime config env vars (LYRIC_CONFIG_MQ_CONNECTION_*):
///   LYRIC_CONFIG_MQ_CONNECTION_URL                 — broker URL (required)
///   LYRIC_CONFIG_MQ_CONNECTION_QUEUENAME           — queue / topic name (required)
///   LYRIC_CONFIG_MQ_CONNECTION_ACKMODE             — "Auto" or "Manual" (default: Auto)
///   LYRIC_CONFIG_MQ_CONNECTION_MAXDELIVERYCOUNT    — redelivery limit (default: 5)
///   LYRIC_CONFIG_MQ_CONNECTION_VISIBILITYTIMEOUTMS — SQS/ASB visibility (default: 30000)
///
/// See docs/03-decision-log.md D056 and lyric-mq/README.md.

@runtime_checked
package Mq

import Std.Core
import Std.Collections
import Mq.Kernel.Net
@cfg(feature = "jvm")
import Mq.Kernel.Jvm

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
  headers:       [MessageHeader]
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

  /// Publish a batch of messages atomically where the broker supports it.
  /// Falls back to sequential publishing where atomic batches are unavailable.
  func publishBatch(messages: in [Message]): Result[Unit, String]
    requires: messages.length > 0
}

// ─── Consumer interface ───────────────────────────────────────────────────────

/// Interface for consuming messages from a queue or subscription.
@stable(since="0.1")
pub interface QueueConsumer {
  /// Block for up to `timeoutMs` milliseconds waiting for the next message,
  /// then invoke `handler`.  Returns Ok(()) when the handler completes
  /// successfully, or Err when the handler fails or no message arrived within
  /// the timeout (Err("timeout")).
  func consume(
    timeoutMs: in Int,
    handler:   func(msg: in Message): Result[Unit, String]
  ): Result[Unit, String]
    requires: timeoutMs > 0

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
  func append(entry: in DeadLetterEntry): Unit

  /// Return all dead-letter entries in insertion order.
  func list(): [DeadLetterEntry]

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
  var entries:    [DeadLetterEntry]
  maxEntries: Int
}

impl DeadLetterStore for InProcessDeadLetterStore {
  func append(entry: in DeadLetterEntry): Unit {
    if entries.length >= maxEntries {
      // Discard oldest entry to stay within capacity.
      entries = entries.tail()
    }
    entries = entries + [entry]
  }

  func list(): [DeadLetterEntry] {
    return entries
  }

  func count(): Int {
    return entries.length
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
    return mqKernelPublish(queueId, message.id, message.body, headersJson)
  }

  func publishBatch(messages: in [Message]): Result[Unit, String]
    requires: messages.length > 0
  {
    val json = messagesToJson(messages)
    return mqKernelPublishBatch(queueId, json)
  }
}

impl QueueConsumer for NativeQueue {
  func consume(
    timeoutMs: in Int,
    handler:   func(msg: in Message): Result[Unit, String]
  ): Result[Unit, String]
    requires: timeoutMs > 0
  {
    match mqKernelConsume(queueId, timeoutMs) {
      case Err(e)       -> Err(e)
      case Ok(msgJson)  -> {
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
    return mqKernelAck(queueId, messageId)
  }

  func nack(messageId: in String, requeue: in Bool): Result[Unit, String]
    requires: messageId.length > 0
  {
    return mqKernelNack(queueId, messageId, requeue)
  }

  func close(): Unit {
    mqKernelClose(queueId)
  }
}

// ─── Config ───────────────────────────────────────────────────────────────────

/// Broker connection and message handling settings.
config Connection {
  url:                  String                          // required; broker URL
  queueName:            String                          // required; queue / topic / subscription name
  ackMode:              AckMode    = AckMode.Auto
  maxDeliveryCount:     Int range 1  ..= 1000  = 5
  visibilityTimeoutMs:  Int range 1000 ..= 600000 = 30000
}

/// Dead-letter store settings.
config DeadLetter {
  enabled:    Bool                      = true
  maxEntries: Int range 1 ..= 1000000   = 10000
}

// ─── Factory functions ────────────────────────────────────────────────────────

/// Open a broker connection using the configured URL and queue name.
/// Returns a `NativeQueue` that implements both `MessageQueue` and
/// `QueueConsumer`.
@stable(since="0.1")
pub func connect(): Result[NativeQueue, String] {
  match mqKernelConnect(Connection.url, Connection.queueName) {
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
      val dlStore = InProcessDeadLetterStore(
        entries    = [],
        maxEntries = DeadLetter.maxEntries)
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
pub func publishBatch(queue: in MessageQueue, messages: in [Message]): Result[Unit, String]
  requires: messages.length > 0
{
  return queue.publishBatch(messages)
}

/// Block for up to `timeoutMs` milliseconds, consume one message, and invoke
/// `handler`.
@stable(since="0.1")
pub func consume(
  consumer:  in QueueConsumer,
  timeoutMs: in Int,
  handler:   func(msg: in Message): Result[Unit, String]
): Result[Unit, String]
  requires: timeoutMs > 0
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

// Connect via the appropriate platform kernel.
func mqKernelConnect(url: in String, queueName: in String): Result[Int, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.connect(url, queueName)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.connect(url, queueName)
}

func mqKernelPublish(queueId: in Int, messageId: in String, body: in String, headersJson: in String): Result[Unit, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.publish(queueId, messageId, body, headersJson)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.publish(queueId, messageId, body, headersJson)
}

func mqKernelPublishBatch(queueId: in Int, messagesJson: in String): Result[Unit, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.publishBatch(queueId, messagesJson)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.publishBatch(queueId, messagesJson)
}

func mqKernelConsume(queueId: in Int, timeoutMs: in Int): Result[String, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.consume(queueId, timeoutMs)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.consume(queueId, timeoutMs)
}

func mqKernelAck(queueId: in Int, deliveryTag: in String): Result[Unit, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.ack(queueId, deliveryTag)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.ack(queueId, deliveryTag)
}

func mqKernelNack(queueId: in Int, deliveryTag: in String, requeue: in Bool): Result[Unit, String] {
  @cfg(feature = "dotnet")
  return Mq.Kernel.Net.nack(queueId, deliveryTag, requeue)
  @cfg(feature = "jvm")
  return Mq.Kernel.Jvm.nack(queueId, deliveryTag, requeue)
}

func mqKernelClose(queueId: in Int): Unit {
  @cfg(feature = "dotnet")
  Mq.Kernel.Net.close(queueId)
  @cfg(feature = "jvm")
  Mq.Kernel.Jvm.close(queueId)
}

// ─── JSON serialisation helpers (private) ────────────────────────────────────

// Serialise a list of MessageHeader to a compact JSON array.
// Format: [{"key":"<k>","value":"<v>"},...]
func headersToJson(headers: in [MessageHeader]): String {
  if headers.length == 0 {
    return "[]"
  }
  var parts: [String] = []
  for h in headers {
    parts = parts + ["{\"key\":\"" + jsonEscape(h.key) + "\",\"value\":\"" + jsonEscape(h.value) + "\"}"]
  }
  return "[" + Std.Collections.joinStrings(parts, ",") + "]"
}

// Serialise a list of Message to a compact JSON array for publishBatch.
// Format: [{"id":"...","body":"...","headers":[...],"deliveryCount":N},...]
func messagesToJson(messages: in [Message]): String {
  if messages.length == 0 {
    return "[]"
  }
  var parts: [String] = []
  for m in messages {
    val hdrJson = headersToJson(m.headers)
    parts = parts + [
      "{\"id\":\"" + jsonEscape(m.id) +
      "\",\"body\":\"" + jsonEscape(m.body) +
      "\",\"headers\":" + hdrJson +
      ",\"deliveryCount\":" + m.deliveryCount.toString() + "}"
    ]
  }
  return "[" + Std.Collections.joinStrings(parts, ",") + "]"
}

// Deserialise a JSON object (produced by the kernel) back into a Message.
// The kernel emits the same format as messagesToJson above.
func messageFromJson(json: in String): Message {
  val id            = jsonExtractString(json, "id")
  val body          = jsonExtractString(json, "body")
  val deliveryCount = jsonExtractInt(json, "deliveryCount")
  // Headers are conveyed in a nested JSON array; parse key/value pairs.
  val hdrsRaw = jsonExtractRaw(json, "headers")
  val headers = parseHeadersJson(hdrsRaw)
  return Message(id = id, body = body, headers = headers, deliveryCount = deliveryCount)
}

// Parse a JSON array of {key,value} objects into a list of MessageHeader.
func parseHeadersJson(json: in String): [MessageHeader] {
  if json == "[]" or json == "" {
    return []
  }
  // Simple linear scan: find each {"key":"...","value":"..."} object.
  var result: [MessageHeader] = []
  var pos: Int = 0
  while pos < json.length {
    val objStart = json.indexOf("{", pos)
    if objStart < 0 { pos = json.length }
    else {
      val objEnd = json.indexOf("}", objStart)
      if objEnd < 0 { pos = json.length }
      else {
        val obj = json.substring(objStart, objEnd + 1)
        val k   = jsonExtractString(obj, "key")
        val v   = jsonExtractString(obj, "value")
        if k.length > 0 or v.length > 0 {
          result = result + [MessageHeader(key = k, value = v)]
        }
        pos = objEnd + 1
      }
    }
  }
  return result
}

// Extract a string field value from a JSON object literal.
// Handles simple escaped strings only; sufficient for broker metadata.
// Extract a string field value from a JSON object literal.
// Limitation: stops at the first unescaped quote after the opening quote;
// values containing \" (escaped quotes) will be truncated at the first \".
// All field values passed through here must be pre-escaped before embedding
// (see jsonEscape); on the decode path, body content is not round-tripped
// through this function — caller must be aware of this constraint.
func jsonExtractString(json: in String, field: in String): String {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return "" }
  val afterColon = start + needle.length
  val q1 = json.indexOf("\"", afterColon)
  if q1 < 0 { return "" }
  val q2 = json.indexOf("\"", q1 + 1)
  if q2 < 0 { return "" }
  return json.substring(q1 + 1, q2)
}

// Extract an integer field value from a JSON object literal.
func jsonExtractInt(json: in String, field: in String): Int {
  val needle = "\"" + field + "\":"
  val start  = json.indexOf(needle)
  if start < 0 { return 0 }
  val afterColon = start + needle.length
  // Skip whitespace.
  var i: Int = afterColon
  while i < json.length and json.charAt(i) == ' ' { i = i + 1 }
  var numStr: String = ""
  while i < json.length and json.charAt(i) != ',' and json.charAt(i) != '}' {
    numStr = numStr + json.charAt(i).toString()
    i = i + 1
  }
  match Std.Core.parseInt(numStr.trim()) {
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
    val ch = json.charAt(i)
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
  var out: String = ""
  var i:   Int    = 0
  while i < s.length {
    val ch = s.charAt(i)
    if ch == '"'       { out = out + "\\\"" }
    else if ch == '\\' { out = out + "\\\\" }
    else if ch == '\n' { out = out + "\\n"  }
    else if ch == '\r' { out = out + "\\r"  }
    else if ch == '\t' { out = out + "\\t"  }
    else               { out = out + ch.toString() }
    i = i + 1
  }
  return out
}
