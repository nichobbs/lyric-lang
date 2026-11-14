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
`lyric-proto`. Server hosting works on both targets for unary and
server-streaming methods over plaintext HTTP/2: register Lyric handlers with
`addUnary` / `addServerStreaming`, then `start` (blocking) or `startHandle` /
`stop` (graceful drain). A handler that panics fails its call with `Internal`.

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
with `lyric-proto` and POSTing it with a dedicated byte-body HTTP client
(`HttpClient` on `dotnet`, `java.net.http` on `jvm`). Traces and metrics are
exported over OTLP/HTTP on both targets; there is no OTLP logs exporter and no
OTLP/gRPC transport.

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

Wire up the OTLP/HTTP exporter in your `main`:

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
The package ships one backend, the in-process broker, which is pure Lyric
and behaves the same on `dotnet` and `jvm`. Networked brokers (RabbitMQ, Azure
Service Bus, SQS, Kafka) are not in the package: they belong in separate
packages that implement `MessageQueue` and `QueueConsumer` and run the
conformance suite `Testing.Conformance.Mq`. See `lyric-mq/README.md`.

```toml
[dependencies]
"Lyric.Mq" = { path = "../lyric-mq" }
```

```lyric
import Mq

func publishOrder(orderId: in String, orderJson: in String): Result[Unit, String] {
  val queue = Mq.connectTo("inmemory://local", "orders")?
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
extra NuGet dependency) and Jakarta Mail on `jvm` (#7462, restored from the
`[maven]` table with `lyric restore`). Senders take no constructor
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

`lyric-storage` offers object storage through the `StorageBucket`
interface. The local filesystem is its only backend and is
production-ready on both targets. S3 and Azure Blob were never implemented
and were removed from the public API (`connectS3` and `connectAzureBlob`);
implement `StorageBucket` in your own package for a remote store.

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

`lyric-search` supports Elasticsearch and Meilisearch backends. Both are
implemented over plain HTTP and JSON on `Std.Http` and `Std.Json` (#5408), with
no native SDK and no per-target kernel. Every operation is tested on both
targets against a fake engine served by `Std.HttpServer`, which answers only
the requests the real engine would accept and returns real response bodies. The
library has not been driven against a real cluster, which is why it is
`experimental`; set `LYRIC_SEARCH_ELASTICSEARCH_URL` (or
`LYRIC_SEARCH_MEILISEARCH_URL`) to run its gated round-trip test against one.

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

## Backends in lyric-ecosystem

The libraries above define interfaces (`StorageBucket`, `JobScheduler`,
`CacheStore`, `SessionStore`, `MessageQueue`) and ship one in-tree reference
backend each (`FlagStore` likewise). Backends that talk to an external
service live in a separate
repository, [`nichobbs/lyric-ecosystem`](https://github.com/nichobbs/lyric-ecosystem),
one package per backend (D552, D561). Each backend implements the interface,
re-exports it with `pub use`, and passes the interface's conformance suite
from `lyric-testing` on every target its manifest claims in `[package]
targets`; a build for a target it does not claim fails with `F0054`.

Application code depends on the interface and picks the backend where it is
wired, so swapping one for another does not touch the code that uses it:

```lyric
import Std.Core
import Storage.S3

func publish(keyId: in String, secret: in String, pdfBase64: in String): Result[String, StorageError] {
  val bucket = connect(awsConfig("my-bucket", "eu-west-1", keyId, secret))?
  put(bucket, "reports/q3.pdf", pdfBase64, "application/pdf")?
  bucket.presignedUrl("reports/q3.pdf", 3600)
}
```

`connect` returns a `Storage.StorageBucket`; everything after that line is
the interface from this chapter. The same holds for the other backends:

```lyric
import Cache.Redis as RedisCache
import Session.Redis as RedisSessions
import Mq.ActiveMq

val cache = RedisCache.connect("redis://cache.internal:6379/1", RedisCache.options("myapp:cache:"))?
val sessions = RedisSessions.connect("redis://sessions.internal:6379", RedisSessions.options("myapp:session:", 3600))?
val orders = Mq.ActiveMq.connectUrl("stomp://app:passcode@broker.internal:61613", "orders")?
```

A job scheduler needs handlers as well as a connection. With Quartz (JVM
only) a registered `JobHandler` runs on a Quartz worker thread:

```lyric
import Std.Core
import Jobs
import Jobs.Quartz

record SendEmail {
  tag: Int
}

impl Jobs.JobHandler for SendEmail {
  func handle(spec: in Jobs.JobSpec): Result[String, Jobs.JobError] {
    Ok("sent " + spec.payload)
  }
}

func run(): Result[Unit, String] {
  val sched = Quartz.create(Quartz.defaultConfig().copy(workerThreads = 8))?
  Quartz.registerHandler(sched, "send-email", SendEmail(tag = 0))
  Quartz.start(sched)?
  val once = sched.enqueue("send-email", "{\"to\":\"a@example.com\"}", 3, 30000)?
  val nightly = sched.schedule("send-email", "{}", "0 3 * * 1-5", 1, 30000)?
  Quartz.shutdown(sched, true)
}
```

Backend-only features sit in a separate module of each package and are not
part of the interface: `Jobs.Quartz.Triggers` (native Quartz cron, intervals,
misfire policy), `Storage.S3.Extras` (byte-level put and get, storage class,
presigned PUT), `Mq.ActiveMq.Extras` (topics, send options, selectors),
`Mq.RabbitMq.Extras` (exchanges, bindings, queue arguments), `Mq.Sqs.Extras`
(queue management, FIFO, redrive), `Flags.Flipt.Extras` (evaluation for an
entity and context).

| Package | Interface | Backend | .NET | JVM | Implementation |
|---|---|---|---|---|---|
| `Lyric.Storage.S3` | `Storage.StorageBucket` | Amazon S3 and S3-compatible stores | real | real | pure Lyric: AWS Signature V4 over `Std.Http`, no SDK |
| `Lyric.Storage.AzureBlob` | `Storage.StorageBucket` | Azure Blob Storage | real | real | pure Lyric: Shared Key and service SAS over `Std.Http` |
| `Lyric.Storage.Gcs` | `Storage.StorageBucket` | Google Cloud Storage | implemented, not yet verified with a real key | implemented, not yet verified with a real key | pure Lyric: XML API with HMAC keys (`GOOG4-HMAC-SHA256`) |
| `Lyric.Jobs.Quartz` | `Jobs.JobScheduler` | Quartz 2.5 (RAM job store) | not supported (`F0054`) | real | Quartz through Maven and auto-FFI |
| `Lyric.Jobs.QuartzNet` | `Jobs.JobScheduler` | Quartz.NET 3 (RAM job store) | real | not supported (`F0054`) | Quartz.NET through NuGet and auto-FFI; same API as `Lyric.Jobs.Quartz` |
| `Lyric.Redis` | none (client) | Redis 6 and later | real | real | pure Lyric: RESP2 and RESP3 over TCP or TLS |
| `Lyric.Cache.Redis` | `Cache.CacheStore` | Redis | real | real | on `Lyric.Redis` |
| `Lyric.Cache.Memcached` | `Cache.CacheStore` | memcached 1.6.10 and later | real | real | pure Lyric: meta protocol on `Lyric.Net`; `clear()` replaces a per-store generation |
| `Lyric.Session.Redis` | `Session.SessionStore` | Redis | real | real | on `Lyric.Redis`; every read-modify-write is one script |
| `Lyric.Mq.ActiveMq` | `Mq.MessageQueue`, `Mq.QueueConsumer` | Apache ActiveMQ Classic | real | real | pure Lyric: STOMP 1.2 over TCP or TLS |
| `Lyric.Mq.RabbitMq` | `Mq.MessageQueue`, `Mq.QueueConsumer` | RabbitMQ 3.12 and 4.0 | real | real | pure Lyric: AMQP 0-9-1 over TCP or TLS |
| `Lyric.Mq.Sqs` | `Mq.MessageQueue`, `Mq.QueueConsumer` | Amazon SQS | real against ElasticMQ; not yet run against AWS | real against ElasticMQ; not yet run against AWS | pure Lyric: AWS JSON 1.0 over `Std.Http`, SigV4 |
| `Lyric.Flags.Flipt` | `Flags.FlagStore` | Flipt v1 | real | real | pure Lyric: Flipt REST over `Std.Http` |
| `Lyric.Net` | none (shared TCP and TLS client) | TCP, TLS | real | real | the one socket kernel behind the Redis, memcached, ActiveMQ and RabbitMQ clients |
| `Lyric.Aws.SigV4` | none (shared signing) | AWS Signature V4 | real | real | pure Lyric; used by the S3, SQS and GCS packages |

The TCP clients (Redis, memcached, ActiveMQ, RabbitMQ) take `rediss://`,
`memcached+tls://`, `stomp+ssl://` and `amqps://` URLs. They verify the server against the system trust store by
default and accept a custom CA, a client certificate and a minimum TLS version,
with the same two-key rule as `Std.Http` for skipping verification.

Two things differ between backends of one interface and are worth reading in
the package README before choosing: what `nack` without requeue does (ActiveMQ
and RabbitMQ dead-letter or drop, SQS deletes), and whether order is kept (an
SQS standard queue is unordered; the conformance suite runs on FIFO queues).
A handler running under `Lyric.Jobs.QuartzNet` cannot be interrupted, so a
timed-out or cancelled attempt is recorded when the handler returns.

All of these are `experimental` and versioned independently of the compiler.
Their CI runs the conformance suites against a real Redis, ActiveMQ, RabbitMQ,
memcached, MinIO, Azurite, ElasticMQ and Flipt on both targets. Until the interface
packages they need are in a release, the repository builds against a pinned
`lyric-lang` commit and resolves the interfaces through
`[workspace.overrides]`; its README has the setup. Each package README lists
usage, configuration, surprises, pinned library versions and known gaps.

---

## Library availability matrix

This matrix summarises which backends are real on which target; each library's README is the detailed source, and the two must agree. The Stability column is the library's `[package] stability` manifest field: `stable` (the backends the library ships are real), `experimental` (real but its surface may still change; its README says `@experimental`) or `incomplete` (a headline backend is not implemented). `lyric publish` refuses an `incomplete` package (`F0052`), and `scripts/ci/check-library-stability.sh` fails CI when a library's README `**Stability:**` line and its manifest disagree. A backend marked `NOT_IMPLEMENTED` returns an explicit error; it is not a silent no-op. SDK-bound backends are separate packages in `nichobbs/lyric-ecosystem`, listed under [Backends in lyric-ecosystem](#backends-in-lyric-ecosystem) (D552, D561, docs/71). At v1.0 the graphics and UI libraries are experimental and the native and wasm32 targets are outside the SemVer guarantee (D548), and a library's `requires:` and `ensures:` clauses are not enforced across the package boundary for its consumers (D549).

| Library | Stability | .NET | JVM | Status |
|---|---|---|---|---|
| lyric-proto | stable | stable | stable (suite in the JVM ecosystem CI job) | D067 |
| lyric-grpc | experimental | client + server (unary, server streaming, metadata, deadlines) + rate limiting real | client + server + rate limiting real | D068, D281, D287 |
| lyric-otel | experimental | recording + OTLP/HTTP export (traces, metrics) real | recording + OTLP/HTTP export (traces, metrics) real | D055, D069 |
| lyric-mq | experimental | in-process broker (pure Lyric); ActiveMQ, RabbitMQ and SQS in `lyric-ecosystem` | in-process broker (pure Lyric); ActiveMQ, RabbitMQ and SQS in `lyric-ecosystem` | D056, D552 |
| lyric-mail | stable | `smtp`, `ses`, `sendgrid` real | `smtp`, `ses`, `sendgrid` real | D062 |
| lyric-storage | experimental | local filesystem (the only in-tree backend); S3, Azure Blob and GCS in `lyric-ecosystem` | local filesystem (the only in-tree backend); S3, Azure Blob and GCS in `lyric-ecosystem` | D056, D552 |
| lyric-search | experimental | implemented over HTTP (#5408) and tested against a fake engine, not yet a real cluster | same code, same tests (default `elasticsearch` backend in CI) | D056 |
| lyric-i18n | stable | stable | stable (suite in CI) | D-progress-628 |
| lyric-feature-flags | stable | stable | stable | D-progress-627 |
| lyric-jobs | experimental | `InProcessJobScheduler` real; Quartz.NET in `Lyric.Jobs.QuartzNet` | `InProcessJobScheduler` real, suite in CI; Quartz in `Lyric.Jobs.Quartz` | D-progress-633, D552 |
| lyric-ws | stable | stable | partial (Undertow WebSocket kernel real and aspects work, suite in CI; fragmented messages and keepalive pings still dotnet-only, Q-WS-001) | D-progress-634 |
| lyric-session | stable | stable | stable (`InProcessSessionStore` and the Lettuce Redis backend real, suite in CI) | D-progress-631 |
| lyric-auth | stable | stable | stable (JWT/API-key verification and `Auth.Aspects.ValidateKey` real, suite in CI) | D-progress-630 |
| lyric-resilience | experimental | stable | stable (`Resilience.Kernel.Jvm`) | D-progress-225 |
| lyric-validation | stable | stable | stable | — |
| lyric-testing | stable | stable | — | — |
| lyric-cache | stable | stable; `InProcessCacheStore` is thread-safe (protected type) | stable; `InProcessCacheStore` is thread-safe (protected type) | D056 |
| lyric-db | experimental | Npgsql and SQLite real (#5407) | PostgreSQL JDBC and SQLite JDBC real, suite in CI (#8932) | D056 |
| lyric-health | stable | stable | stable | D057 |
| lyric-web | experimental | stable | stable | D057 |
| lyric-logging | stable | stable | stable (suite in CI) | D054 |
| lyric-forms | experimental | experimental | experimental | D137; see Chapter 31 |
| lyric-mcp | experimental | experimental, real (stdio, spawned-child round trips) | experimental, real | D129, D133 |
| lyric-docker | experimental | Unix-socket client real | Unix-socket client real (JDK 16+); named pipes planned | D056, D-progress-541 |
| lyric-lambda | experimental | experimental; `aws` and `local` runtimes, six event sources and authorizers real; no HTTP entry point and no response streaming (withdrawn) | experimental; same dispatch, no Maven dependencies | D062, D063, D064, D552 |
| lyric-aws-secrets | incomplete | `local` and `aws` real | `jvm` real | D064, D230, D552; the annotation path is not declared on `--target native` (no annotation metadata, #8524) |
| lyric-aws-xray | experimental | experimental; real SDK binding | experimental; SDK binding real, `Tracing` aspect broken (B′-mode weaver, docs/71 phase 1) | D064 |
| lyric-ui | experimental | experimental | experimental | D137, D139; see Chapter 31 |

> **Note:** `lyric-jobs`, `lyric-ws`, `lyric-session`, `lyric-auth`, `lyric-resilience`,
> `lyric-validation`, `lyric-testing`, `lyric-cache`, `lyric-db`, `lyric-health`,
> `lyric-web`, and `lyric-logging` are documented in their respective README files
> in the repository. A dedicated book chapter covering these libraries is planned
> for a future release.
