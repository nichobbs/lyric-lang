# lyric-aws-xray

AWS X-Ray integration for [Lyric](https://github.com/nichobbs/lyric-lang). Provides distributed tracing via X-Ray subsegments and a B-mode aspect template for automatic call instrumentation.

> **Status**: @experimental — `aws` and `jvm` bind directly to the real AWS X-Ray SDKs (`AWSXRayRecorder.Core` / `aws-xray-recorder-sdk-core`) via `extern type` + auto-FFI, verified against those real SDK assemblies (no daemon or AWS credentials required — see "Verification" below), but the end-to-end pipeline has not been exercised against a live X-Ray segment service in CI, and the `Tracing` aspect template does not yet work on `jvm` (see "Platform parity").

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `aws` | Amazon.XRay.Recorder.Core (.NET) | `currentSubsegment`/`beginSubsegment`/`endSubsegment`/`annotate`/`metadata` verified against the real SDK. The `Tracing` aspect works (cross-package B'-mode weaving is fine on `.NET`). |
| `jvm` | aws-xray-recorder-sdk-core (Java) | `currentSubsegment`/`beginSubsegment`/`endSubsegment`/`annotate`/`metadata` verified against the real SDK. The `Tracing` aspect does **not** work on this target: cross-package `from`-instance aspect instantiation is B'-mode, and B'-mode's JVM call-context codegen has a pre-existing weaver bug (`NoSuchMethodError` on the synthesised `__LyricBModeCallContext` at runtime) unrelated to this library — use `beginSubsegment`/`endSubsegment` directly instead until that's fixed. |
| `local` | Local stub (no-op) | Available |

## Verification

`aws` and `jvm` are verified by `tests/xray_tests.l` compiling and running against the real `AWSXRayRecorder.Core` NuGet package and `aws-xray-recorder-sdk-core` Maven artifact respectively — no live X-Ray daemon or AWS credentials are needed: both SDKs are designed to run without one (segment/subsegment emission is fire-and-forget UDP, silently dropped when nothing is listening) and default to a log-and-continue `ContextMissingStrategy` rather than throwing when no segment/subsegment is active. What is **not** verified is that a real X-Ray backend actually receives the emitted trace data — that needs a live daemon or the X-Ray console.

## Packages

| Package | Description |
|---|---|
| `AwsXRay` | Core: subsegment handle, `beginSubsegment`/`endSubsegment`, annotation/metadata, `Tracing` aspect template. The extern boundary for `aws`/`jvm` is `@cfg`-gated directly inside this package (`src/xray.l`), not a separate `Kernel` package. |

## Installation

```toml
[dependencies]
"Lyric.AwsXRay" = { path = "../lyric-aws-xray" }
```

## Quick start

### Basic tracing with aspects

Apply the `Tracing` aspect template to functions you want to trace:

```lyric
import AwsXRay
import Lambda

aspect TraceHandlers from AwsXRay.Tracing {
  matches: name like "handle*"
  config {
    enabled: Bool = true
  }
}

func handleGetUser(userId: in Int): Result[User, Web.ApiError] {
  // Automatically traced in X-Ray
  // Subsegment created with name "handleGetUser"
  // Automatic timing, exception capture, annotation from aspect
}
```

### Adding annotations and metadata

Annotate and metadata the active subsegment:

```lyric
import AwsXRay
import Std.Core

func callExternalService(id: String): Result[String, String] {
  // Get the current subsegment (created by the Tracing aspect)
  val handle = AwsXRay.currentSubsegment()
  
  // Add indexed annotation for filtering in X-Ray console
  AwsXRay.annotate(handle, "user_id", id)
  
  // Add unindexed metadata for debugging
  AwsXRay.metadata(handle, "request_type", "lookup")

  // Do the work
  val result = makeExternalCall(id)
  
  result
}
```

## Subsegments

A **subsegment** is a timed unit of work within a Lambda invocation. Subsegments are created automatically by the `Tracing` aspect template. You can add annotations and metadata to the active subsegment using the public API.

### Getting the active subsegment

Inside a function wrapped by the `Tracing` aspect, get the current subsegment handle:

```lyric
import AwsXRay

val handle = AwsXRay.currentSubsegment()
```

### Annotating a subsegment

Add key-value annotations for filtering and faceting in the X-Ray console:

```lyric
import AwsXRay

val handle = AwsXRay.currentSubsegment()
AwsXRay.annotate(handle, "user_id", userId.toString())
AwsXRay.annotate(handle, "request_status", "success")
AwsXRay.annotate(handle, "cache_hit", cacheHit.toString())
```

Annotations are indexed and appear as facets in the X-Ray console — use them for operationally important dimensions.

### Adding metadata

Store arbitrary structured data for debugging:

```lyric
import AwsXRay

val handle = AwsXRay.currentSubsegment()
AwsXRay.metadata(handle, "request_body", jsonRequest)
AwsXRay.metadata(handle, "database_config", dbConfig.toString())
```

Metadata is not indexed and appears only in detailed trace records — use for raw diagnostic data.

## Aspect template

### `AwsXRay.Tracing`

Automatically creates a subsegment for every matched function, capturing timing and exceptions.

**Mode**: B-mode (entry/exit wrapping, no special return type handling)

**Behavior**:
1. On entry: create a subsegment named after the function
2. On success: annotate with `outcome = "success"`, close, and continue
3. On exception/error: annotate with `outcome = "error"`, capture exception details, close, and re-raise

```lyric
import AwsXRay

aspect TraceAll from AwsXRay.Tracing {
  matches: name like "*"
  config {
    enabled: Bool = true
  }
}
```

| Config field | Type | Default | Env var |
|---|---|---|---|
| `enabled` | `Bool` | `true` | `LYRIC_ASPECT_<LocalName>_ENABLED` |
| `namespace` | `String` | `""` | `LYRIC_ASPECT_<LocalName>_NAMESPACE` |

The `namespace` field is prepended to the subsegment name: if `namespace = "MyService"`, the subsegment for `handleGetUser` becomes `"MyService.handleGetUser"`.

## Low-level API

### `beginSubsegment(name)` / `endSubsegment(handle)`

Open and close a subsegment manually — useful for programmatic control over
subsegment boundaries instead of (or nested inside) an aspect-wrapped call.
This is what the `Tracing` aspect's `around` advice calls internally.

```lyric
pub func beginSubsegment(name: in String): SubsegmentHandle
pub func endSubsegment(handle: in SubsegmentHandle): Unit
```

```lyric
import AwsXRay

func processOrder(orderId: in Long): Result[Unit, String] {
  val seg = AwsXRay.beginSubsegment("processOrder")
  AwsXRay.annotate(seg, "order_id", orderId.toString())
  val result = saveOrder(orderId)
  AwsXRay.endSubsegment(seg)
  result
}
```

### `currentSubsegment()`

Get the active subsegment opened by the enclosing `Tracing` aspect.

```lyric
pub func currentSubsegment(): SubsegmentHandle
```

**Returns**: A handle to the current subsegment. When called outside an aspect-wrapped function, returns a no-op handle.

### `annotate(handle, key, value)`

Add an indexed annotation to the subsegment.

```lyric
pub func annotate(
  handle: in SubsegmentHandle,
  key: in String,
  value: in String
): Unit
```

Annotations are **indexed** and appear as facets in the X-Ray console for filtering and faceting. Use for operationally important dimensions: `user_id`, `status`, `cache_hit`, etc.

### `metadata(handle, key, value)`

Add unindexed metadata to the subsegment.

```lyric
pub func metadata(
  handle: in SubsegmentHandle,
  key: in String,
  value: in String
): Unit
```

Metadata is **not indexed**; it appears in detailed trace records. Use for raw diagnostic data: JSON payloads, config dumps, etc.

## Integration with Lambda

X-Ray traces are automatically correlated with Lambda invocations when running in the AWS Lambda environment.

Each Lambda invocation automatically creates a **root segment** (managed by the Lambda runtime); your subsegments are automatically nested underneath it.

```lyric
import Lambda
import AwsXRay
import Web

aspect TraceHandlers from AwsXRay.Tracing {
  matches: name like "handle*"
}

func handleGetUser(userId: in Int): Result[User, Web.ApiError] {
  // Automatically creates subsegment "handleGetUser" under Lambda root segment
  // ... handler code ...
}

func main(): Int {
  var router = Web.create()
  router = Web.addGet(router, "/users/{id}", "MyApp.handleGetUser")
  Lambda.serve(Lambda.newApp() |> Lambda.withRouter(router))
}
```

## Integration with lyric-logging

Combine X-Ray tracing with structured logging for both real-time observability and historical audit:

```lyric
import AwsXRay
import Lyric.Logging

val log = Lyric.Logging.getLogger("MyApp.Service")

aspect TraceOrder from AwsXRay.Tracing {
  matches: name like "processOrder"
}

func processOrder(orderId: in Long): Result[Unit, String] {
  val handle = AwsXRay.currentSubsegment()
  AwsXRay.annotate(handle, "order_id", orderId.toString())
  
  Lyric.Logging.info(log, "processing order")
  
  // Do the work
  val result = saveOrder(orderId)
  
  match result {
    case Ok(_)  -> {
      Lyric.Logging.info(log, "order saved", [Lyric.Logging.field("order_id", orderId.toString())])
      Ok(Unit)
    }
    case Err(e) -> {
      Lyric.Logging.error(log, "order failed", [Lyric.Logging.field("error", e)])
      Err(e)
    }
  }
}
```

## Local development (feature = "local")

When built with the `local` feature, X-Ray operations are no-ops:

- `currentSubsegment()` returns a no-op dummy handle
- `annotate()` and `metadata()` do nothing when called on the dummy handle
- The `Tracing` aspect template still wraps matched functions but produces no X-Ray subsegments

This allows the same code to run locally without AWS X-Ray daemon or permission requirements.

## Production checklist

- Lambda execution role has `xray:PutTraceSegments` and `xray:PutTelemetryRecords`
- X-Ray daemon is running in the VPC (if using VPC; Lambda on public subnets uses AWS-managed X-Ray endpoint)
- X-Ray sampling rules are configured (default: 1 request per second)
- Subsegment names are meaningful and stable (avoid high-cardinality names like user IDs)
- Annotations use low-cardinality values (status, outcome, type) for effective filtering
- Metadata is used for high-volume data (full request bodies, config dumps)

## Package layout

```
lyric-aws-xray/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    xray.l                    AwsXRay (subsegments, annotations, Tracing aspect,
                               and the aws/jvm/local extern boundary, each
                               @cfg-gated inline in this one file)
    _kernel/                  orphaned scaffolding predating the extern-type
                               boundary in xray.l — not registered in
                               lyric.toml, not imported by anything; kept
                               (not deleted) but not the live code path
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-lambda` — Lambda runtime adapter; integrates automatically with X-Ray
- `lyric-logging` — Structured logging; complements X-Ray for complete observability
- [AWS X-Ray User Guide](https://docs.aws.amazon.com/xray/) (external reference)
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D064 — design decisions
