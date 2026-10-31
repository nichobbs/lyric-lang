# Chapter 29: Application Libraries

Lyric ships a suite of optional libraries for common application concerns.
Each library follows the same pattern: a `lyric.toml` dependency, an import,
and a public API that composes with the stdlib and with each other.

Every code example in this chapter is written against the library's
current, shipped `pub` API (as declared in its `src/` package). Where a
backend is not yet implemented, the example says so — do not assume every
listed operation is production-ready on every target; see each library's
`README.md` and the [Library availability matrix](#library-availability-matrix)
at the end of this chapter for the authoritative status.

---

## lyric-proto — Protocol Buffers

The `lyric-proto` library provides a pure-Lyric proto3 wire-format encoder
and decoder. No `.proto` file compilation step is required; messages are
built as an ordered list of `ProtoField` values and encoded in one call.
`.NET` is the only implemented target — JVM is Phase 6 (planned).

```toml
[dependencies]
"Lyric.Proto" = { path = "../lyric-proto" }
```

```lyric
import Proto
import Std.Encoding

// Construct fields with the typed helper functions, then encode them
// together as one message.
val fields = [
  Proto.stringField(1, Encoding.encodeUtf8("Alice")),
  Proto.sint32Field(2, 42),
]
val bytes = Proto.encodeMessage(fields)
```

Decoding returns a list of `DecodedField` union cases (`DecodedVarint`,
`DecodedBytes`, `DecodedFixed32`, `DecodedFixed64`) that you match on by
field number:

```lyric
match Proto.decodeMessage(bytes) {
  case Ok(decoded) -> {
    match Proto.findBytes(decoded, 1) {
      case Some(nameBytes) -> ()
      case None -> ()
    }
  }
  case Err(msg) -> ()
}
```

`lyric-proto` is used by `lyric-grpc` for payload framing and by `lyric-otel`
for OTLP export. Use it directly when constructing custom protobuf messages
without a generated schema.

---

## lyric-grpc — gRPC Client

`lyric-grpc` is `@experimental`. The client is real on both targets, backed by
`Grpc.Net.Client` on `.NET` and grpc-java on the JVM, and tested end to end
against an in-process gRPC server: channels (`openChannel`/`closeChannel`),
unary calls (`callUnary`), server streaming (`openServerStream`/`nextMessage`/
`closeStream`), call metadata, deadlines, and the in-process rate limiter
(`checkRateLimit`). A failed call is `Err(GrpcStatus)` carrying the server's
status code and message. Payloads are raw protobuf bytes: compose with
`lyric-proto`. Server hosting (`start`/`startHandle`/`stop`) is not
implemented on either target and fails loudly (#8642).

```toml
[dependencies]
"Lyric.Grpc" = { path = "../lyric-grpc" }
"Lyric.Proto" = { path = "../lyric-proto" }
```

```lyric
import Grpc
import Proto
import Std.Encoding

func callGreet(name: in String): Result[slice[Byte], Grpc.GrpcStatus] {
  match Grpc.openChannel("https://grpc.example.com:50051") {
    case Err(e) -> return Err(Grpc.unavailable(e))
    case Ok(channel) -> {
      val payload = Proto.encodeMessage([Proto.stringField(1, Encoding.encodeUtf8(name))])
      val result = Grpc.callUnary(channel, "hello.Greeter", "SayHello", payload, Grpc.defaultOptions())
      Grpc.closeChannel(channel)
      result
    }
  }
}
```

---

## lyric-otel — OpenTelemetry

`lyric-otel` records spans and metrics as a plain in-process Lyric record
(no BCL/JDK dependency, so recording works identically on both targets)
and exports them over OTLP/HTTP by building the protobuf payload directly
with `lyric-proto` and POSTing it with a dedicated HTTP client. OTLP export
is real on `dotnet`; on `jvm`, spans/metrics are still recorded but nothing
drains them yet — every `configureOtlp*` call returns `Err`. OTLP/gRPC
transport is not implemented on either target.

```toml
[dependencies]
"Lyric.OTel" = { path = "../lyric-otel" }
```

```lyric
import OTel

func processOrder(): Unit {
  val span = OTel.startSpan("processOrder", 1)
  // ... work ...
  OTel.endSpan(span)
}
```

Wire up the OTLP/HTTP exporter in your `main` (`dotnet` only today):

```lyric
import OTel.Otlp

func main(): Unit {
  match OTel.Otlp.configureOtlp(OTel.Otlp.defaultConfig()) {
    case Ok(()) -> ()
    case Err(e) -> ()
  }
  // ... start server ...
}
```

---

## lyric-mq — Message Queues

`lyric-mq` provides a transport-agnostic message queue abstraction.
**Only the `inmemory` backend is production-ready, and only on `dotnet`.**
`rabbitmq`, `azureservicebus`, `sqs`, and `kafka` all type-check, but on
`dotnet` every one of them returns `Err("... not yet implemented")` from
`connect()`, and on `jvm` there is no working backend of any kind — see
`lyric-mq/README.md` for the exact per-broker/per-target gaps.

```toml
[dependencies]
"Lyric.Mq" = { path = "../lyric-mq" }
```

```lyric
import Mq

func publishOrder(orderId: in String, orderJson: in String): Result[Unit, String] {
  val queue = Mq.connectTo("amqp://localhost", "orders")?
  return Mq.publish(queue, Mq.Message(
    id            = orderId,
    body          = orderJson,
    headers       = [],
    deliveryCount = 0
  ))
}

func consumeOrders(queue: in Mq.NativeQueue): Result[Unit, String] {
  return Mq.consume(queue, 5000, { msg ->
    // ... process msg.body ...
    Ok(())
  })
}
```

The `Idempotent` and `DeadLetter` aspect templates (`Mq.Aspects`) reduce
boilerplate for at-least-once delivery patterns.

---

## lyric-mail — Email

`lyric-mail` sends email through one `MailSender` interface. `ses` (SES v2
with AWS Signature V4) and `sendgrid` (v3 `mail/send`) are plain HTTPS APIs
implemented once in Lyric over `Std.Http`, so they work on `dotnet` and
`jvm` alike. The `smtp` provider uses `System.Net.Mail` on `dotnet` (no
extra NuGet dependency) and returns `Err(code = "NOT_IMPLEMENTED")` on `jvm`
pending a Jakarta Mail extern kernel (#7462). Senders take no constructor
arguments — configuration (host, port, credentials, the envelope `From`
address) is read from `LYRIC_CONFIG_SMTP_*` / `LYRIC_CONFIG_SENDER_*`
environment variables.

```toml
[dependencies]
"Lyric.Mail" = { path = "../lyric-mail" }
```

```lyric
import Mail

func sendWelcome(to: in String, name: in String): Result[Unit, Mail.MailError] {
  val sender = Mail.connectSmtp()?
  val result = Mail.sendSimple(sender, to, "Welcome, " + name + "!", "Thanks for signing up.")
  sender.close()
  return result
}
```

`Mail.send`/`sendSimple`/`sendHtml` reject a message with no recipients
(`NO_RECIPIENTS`), an implausible recipient address, a header-injection
payload (CRLF/NUL in the subject, an address, or an attachment field —
CWE-93), or attachments totalling more than
`Mail.maxTotalAttachmentBytes` (25 MiB) before any transport dispatch —
each as a structured `Err`, never a panic, since every one of those
fields is client-controllable data.

---

## lyric-storage — Object Storage

`lyric-storage` abstracts over S3, Azure Blob, and the local filesystem
via the `StorageBucket` interface. **Only the local filesystem backend is
production-ready, and it is production-ready on both targets.**
`connectS3()`/`connectAzureBlob()` compile and type-check on both
targets, but every operation on the bucket they return is
`Err(StorageError(code = "NOT_IMPLEMENTED"))` — native SDK bindings are
still pending.

```toml
[dependencies]
"Lyric.Storage" = { path = "../lyric-storage" }
```

```lyric
import Storage

func uploadAvatar(userId: in String, base64Data: in String): Result[Storage.StorageMetadata, Storage.StorageError] {
  val bucket = Storage.connectLocal("/var/data/avatars", "avatars")?
  return Storage.put(bucket, userId + ".png", base64Data, "image/png")
}

func getAvatar(userId: in String): Result[Storage.StorageObject, Storage.StorageError] {
  val bucket = Storage.connectLocal("/var/data/avatars", "avatars")?
  return Storage.get(bucket, userId + ".png")
}
```

---

## lyric-search — Search

`lyric-search` supports Elasticsearch and Meilisearch backends. Real
kernel-level HTTP bindings exist for both on both targets, but the public
`Search` API does not call them yet (#5067), so neither backend is
reachable today; `connectElasticsearch`/`connectMeilisearch` are shown
below for reference.

```toml
[dependencies]
"Lyric.Search" = { path = "../lyric-search" }
```

```lyric
import Search
import Std.Collections

async func indexUser(id: in String, name: in String): Result[Search.IndexResult, Search.SearchError] {
  val client = await Search.connectElasticsearch("http://localhost:9200", "", "", "", 5000, 30000)?
  var fields: Map[String, String] = newMap()
  fields.add("name", name)
  val doc = Search.makeDoc("users", id, fields)
  return Search.index(client, doc)
}
```

---

## lyric-i18n — Internationalization

`lyric-i18n` loads translations from a JSON blob (or a directory of
per-locale files) and resolves translated strings with `{placeholder}`
substitution. It is stable on `dotnet` and stable on `jvm` (one known
gap, #5439).

```toml
[dependencies]
"Lyric.I18n" = { path = "../lyric-i18n" }
```

```lyric
import I18n
import Std.Collections

func greet(store: in I18n.TranslationStore, localeTag: in String, name: in String): String {
  val locale = I18n.makeLocale(localeTag)
  var vars: Map[String, String] = newMap()
  vars.add("name", name)
  return I18n.translateWithLocale(store, "greeting", locale, vars)
}
```

Translations JSON (loaded with `I18n.fromJson(json)` or
`I18n.loadFromPath(dirPath)`):

```json
{ "en": { "greeting": "Hello, {name}!" }, "es": { "greeting": "Hola, {name}!" } }
```

Locale fallback: `en-GB` falls back to `en`, then to the default locale.

---

## lyric-feature-flags — Feature Toggles

`lyric-feature-flags` provides an in-process `FlagStore` for safe
rollouts, A/B testing, and kill switches. There is no remote
(HTTP-polling) store — the earlier `connectRemote()` scaffolding never
resolved to a real binding on either backend and was removed
(D-progress-627); implement `FlagStore` yourself against `Std.Http` for a
LaunchDarkly-, Unleash-, or custom-endpoint-backed store. It is stable on
both `dotnet` and `jvm`.

```toml
[dependencies]
"Lyric.Flags" = { path = "../lyric-feature-flags" }
```

```lyric
import Flags

func processPayment(store: in Flags.FlagStore, order: in Order): Unit {
  if Flags.getBool(store, "new_payment_flow", false) {
    processWithNewFlow(order)
  } else {
    processWithLegacyFlow(order)
  }
}
```

The `FlagGated` aspect template (`Flags.Aspects`) wraps a function so it
only runs when a named flag is enabled. It reads from a process-global
registry (`Flags.Registry`), not a `FlagStore` instance — since aspect
`config { }` fields can't carry a store reference — so register the flag
there at startup:

```lyric
import Flags.Aspects
import Flags.Registry

aspect NewPaymentFlowGate from Flags.Aspects.FlagGated {
  matches: name like "processWithNewFlow"
  config { flagName: String = "new_payment_flow" }
}

func main(): Unit {
  Flags.Registry.registerBoolFlag("new_payment_flow", true)
  // ...
}
```

---

## Library availability matrix

| Library | .NET | JVM | Status |
|---|---|---|---|
| lyric-proto | stable | planned (Phase 6) | D067 |
| lyric-grpc | client (unary, server streaming, metadata, deadlines) + rate limiting real; server hosting not implemented (#8642) | client + rate limiting real; server hosting not implemented (#8642) | D068, D281 |
| lyric-otel | recording + OTLP/HTTP export real | recording real; OTLP export not implemented | D055, D069 |
| lyric-mq | only `inmemory` real, other brokers `NOT_IMPLEMENTED` | no working backend | D056, #6511 |
| lyric-mail | `smtp`, `ses`, `sendgrid` real | `ses`/`sendgrid` real; `smtp` `NOT_IMPLEMENTED` (#7462) | D062 |
| lyric-storage | local filesystem real; S3/Azure Blob `NOT_IMPLEMENTED` | local filesystem real; S3/Azure Blob `NOT_IMPLEMENTED` | D056 |
| lyric-search | kernel bindings exist, unreachable from public API (#5067) | same | D056 |
| lyric-i18n | stable | stable (1 known gap, #5439) | D-progress-628 |
| lyric-feature-flags | stable | stable | D-progress-627 |
| lyric-jobs | stable | partial (`InProcessJobScheduler` broken, #5456; Quartz backend real) | D-progress-633 |
| lyric-ws | stable | partial (Undertow WebSocket kernel real; 2 known gaps, #5453/#5454; aspects blocked on B′-mode weaver gap) | D-progress-634 |
| lyric-session | stable | stable (1 known gap, `InProcessSessionStore`, #5451; Lettuce Redis backend real) | D-progress-631 |
| lyric-auth | stable | stable (`Auth.Aspects.ValidateKey` is .NET-only pending the B′-mode weaver fix; JWT/API-key verification real) | D-progress-630 |
| lyric-resilience | stable | stable (`Resilience.Kernel.Jvm`) | D-progress-225 |
| lyric-validation | stable | stable | — |
| lyric-testing | stable | — | — |
| lyric-cache | stable | stable | D056 |
| lyric-db | stable | planned | D056 |
| lyric-health | stable | stable | D057 |
| lyric-web | stable | stable | D057 |
| lyric-logging | stable | planned | D054 |
| lyric-forms | experimental | experimental | D137; see Chapter 31 |
| lyric-ui | experimental | experimental | D137, D139; see Chapter 31 |

> **Note:** `lyric-jobs`, `lyric-ws`, `lyric-session`, `lyric-auth`, `lyric-resilience`,
> `lyric-validation`, `lyric-testing`, `lyric-cache`, `lyric-db`, `lyric-health`,
> `lyric-web`, and `lyric-logging` are documented in their respective README files
> in the repository. A dedicated book chapter covering these libraries is planned
> for a future release.
