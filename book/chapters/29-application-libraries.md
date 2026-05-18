# Chapter 29: Application Libraries

Lyric ships a suite of optional libraries for common application concerns.
Each library follows the same pattern: a `lyric.toml` dependency, an import,
and a public API that composes with the stdlib and with each other.

---

## lyric-proto — Protocol Buffers

The `lyric-proto` library provides a pure-Lyric proto3 wire-format encoder
and decoder.  No `.proto` file compilation step is required; messages are
described as Lyric records.

```toml
[dependencies]
"Lyric.Proto" = { path = "../lyric-proto" }
```

```lyric
import Lyric.Proto

val buf = Proto.newBuffer()
Proto.writeVarint(buf, 1, 42)        // field 1, value 42
Proto.writeString(buf, 2, "Alice")   // field 2, value "Alice"
val bytes = Proto.finish(buf)
```

`lyric-proto` is used by `lyric-grpc` for payload framing and by `lyric-otel`
for OTLP export.  Use it directly when constructing custom protobuf messages
without a generated schema.

---

## lyric-grpc — gRPC Client

`lyric-grpc` wraps `Grpc.Net.Client` on .NET and `io.grpc.ManagedChannel`
on the JVM (Phase 6).  Payloads flow as raw `slice[Byte]` so callers
compose with `lyric-proto` for encoding.

```toml
[dependencies]
"Lyric.Grpc" = { path = "../lyric-grpc" }
"Lyric.Proto" = { path = "../lyric-proto" }
```

```lyric
import Lyric.Grpc
import Lyric.Proto

async func callGreet(name: in String): String {
  val channel = Grpc.newChannel("https://grpc.example.com")
  val buf = Proto.newBuffer()
  Proto.writeString(buf, 1, name)
  val req = Grpc.newRequest("/hello.Greeter/SayHello", Proto.finish(buf))
  val resp = await Grpc.invoke(channel, req)
  resp.body[0]
}
```

---

## lyric-otel — OpenTelemetry

`lyric-otel` exports traces, metrics, and logs via the OTel .NET SDK.
The OTLP exporter (`OTel.Otlp`) ships the data to any OpenTelemetry
Collector over gRPC or HTTP/protobuf.

```toml
[dependencies]
"Lyric.OTel" = { path = "../lyric-otel" }
```

```lyric
import OTel

val tracer = OTel.tracer("my-service")
val span   = OTel.startSpan(tracer, "processOrder")
// ... work ...
OTel.endSpan(span)
```

Wire up the OTLP exporter in your `main`:

```lyric
func main(): Unit {
  OTel.configure(OTel.otlpGrpc("http://otel-collector:4317"))
  // ... start server ...
}
```

---

## lyric-mq — Message Queues

`lyric-mq` provides a transport-agnostic message queue abstraction.
Backends are selected via feature flags: `rabbitmq`, `azure-service-bus`,
`sqs`, and `kafka`.

```toml
[dependencies]
"Lyric.Mq" = { path = "../lyric-mq", features = ["rabbitmq"] }
```

```lyric
import Lyric.Mq

async func publishOrder(order: in Order): Unit {
  val queue = Mq.connect("amqp://localhost", "orders")
  await Mq.publish(queue, Mq.message(order.id, toJson(order)))
}

async func consumeOrders(): Unit {
  val queue = Mq.connect("amqp://localhost", "orders")
  await Mq.consume(queue, { msg: Mq.Message ->
    val order = fromJson[Order](msg.body)
    await processOrder(order)
    Mq.ack(msg)
  })
}
```

The `Idempotent` and `DeadLetter` aspect templates reduce boilerplate for
at-least-once delivery patterns.

---

## lyric-mail — Email

`lyric-mail` sends email via SMTP (MailKit), Amazon SES, or SendGrid,
selected at wire-up time.

```toml
[dependencies]
"Lyric.Mail" = { path = "../lyric-mail" }
```

```lyric
import Lyric.Mail

async func sendWelcome(to: in String, name: in String): Unit {
  val sender = Mail.smtpSender("smtp.example.com", 587, "user", "pass")
  val msg = Mail.message(
    from    = "noreply@example.com",
    to      = [to],
    subject = "Welcome, " + name + "!",
    text    = "Thanks for signing up."
  )
  await Mail.send(sender, msg)
}
```

---

## lyric-storage — Object Storage

`lyric-storage` abstracts over S3, Azure Blob, and the local filesystem
via the `StorageBucket` interface.

```toml
[dependencies]
"Lyric.Storage" = { path = "../lyric-storage" }
```

```lyric
import Lyric.Storage

async func uploadAvatar(userId: in String, data: in slice[Byte]): Unit {
  val bucket = Storage.s3Bucket("my-avatars", "us-east-1")
  await Storage.put(bucket, "avatars/" + userId + ".png", data)
}

async func getAvatar(userId: in String): Result[slice[Byte], String] {
  val bucket = Storage.s3Bucket("my-avatars", "us-east-1")
  await Storage.get(bucket, "avatars/" + userId + ".png")
}
```

---

## lyric-search — Search

`lyric-search` supports Elasticsearch and Meilisearch backends.

```toml
[dependencies]
"Lyric.Search" = { path = "../lyric-search" }
```

```lyric
import Lyric.Search

async func indexProduct(product: in Product): Unit {
  val client = Search.elasticsearchClient("http://localhost:9200")
  await Search.index(client, "products", product.id, toJson(product))
}

async func findProducts(query: in String): slice[String] {
  val client = Search.elasticsearchClient("http://localhost:9200")
  val result = await Search.search(client, "products", query)
  result.hits
}
```

---

## lyric-i18n — Internationalization

`lyric-i18n` loads BCP 47 locale files and resolves translated strings
with `{placeholder}` substitution.

```toml
[dependencies]
"Lyric.I18n" = { path = "../lyric-i18n" }
```

```lyric
import Lyric.I18n

func greet(locale: in String, name: in String): String {
  val store = I18n.loadJson("translations/", locale)
  I18n.translate(store, "greeting", [("name", name)])
}
```

Translation file `translations/en.json`:

```json
{ "greeting": "Hello, {name}!" }
```

Locale fallback: `en-GB` falls back to `en`, then to the default locale.

---

## lyric-feature-flags — Feature Toggles

`lyric-feature-flags` provides runtime feature flags with in-process and
HTTP polling backends.

```toml
[dependencies]
"Lyric.Flags" = { path = "../lyric-feature-flags" }
```

```lyric
import Lyric.Flags

func processPayment(order: in Order): Unit {
  if Flags.getBool("new_payment_flow", false) {
    processWithNewFlow(order)
  } else {
    processWithLegacyFlow(order)
  }
}
```

The `FlagGated` aspect template wraps a function so it is only called when a
named flag is enabled:

```lyric
@FlagGated(flag = "new_payment_flow")
func processWithNewFlow(order: in Order): Unit {
  // ...
}
```

---

## Library availability matrix

| Library | .NET | JVM (Phase 6) | Status |
|---|---|---|---|
| lyric-proto | stable | planned | D067 |
| lyric-grpc | stable | planned | D068 |
| lyric-otel | stable | planned | D055, D069 |
| lyric-mq | stable | planned | D056 |
| lyric-mail | stable | planned | D056 |
| lyric-storage | stable | planned | D056 |
| lyric-search | stable | planned | D056 |
| lyric-i18n | stable | planned | D056 |
| lyric-feature-flags | stable | planned | D056 |
