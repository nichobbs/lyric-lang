# lyric-aws-xray

AWS X-Ray integration for [Lyric](https://github.com/nichobbs/lyric-lang). Provides distributed tracing via X-Ray subsegments and a B-mode aspect template for automatic call instrumentation.

> **Status**: Library source is complete. Both `.NET` and JVM targets are supported via feature flags.

## Platform parity

| Feature flag | Backend | Status |
|---|---|---|
| `aws` | Amazon.XRay.Recorder.Core (.NET) | Available |
| `jvm` | aws-xray-recorder-sdk-core (Java) | Available |
| `local` | Local stub (no-op) | Available |

## Packages

| Package | Description |
|---|---|
| `AwsXRay` | Core: subsegment handle, annotation/metadata, `Tracing` aspect template |
| `AwsXRay.Kernel.Net` | Extern boundary (one per feature) |

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

### Manual instrumentation

Create subsegments for custom operations:

```lyric
import AwsXRay
import Std.Core

func callExternalService(id: String): Result[String, String] {
  // Begin a subsegment named "ExternalService.lookup"
  match AwsXRay.beginSubsegment("ExternalService.lookup") {
    case Ok(handle) -> {
      // Annotate the subsegment with custom metadata
      handle = AwsXRay.annotate(handle, "user_id", id)
      handle = AwsXRay.metadata(handle, "request_type", "lookup")

      // Do the work
      val result = makeExternalCall(id)

      // Close the subsegment (automatic timing)
      AwsXRay.endSubsegment(handle)
      result
    }
    case Err(e) -> {
      Err(e)
    }
  }
}
```

## Subsegments

A **subsegment** is a timed unit of work within a Lambda invocation. Each subsegment is named, timed automatically, and can carry custom annotations and metadata.

### Creating a subsegment

```lyric
import AwsXRay

match AwsXRay.beginSubsegment("operation_name") {
  case Ok(handle) -> {
    // Use handle to add annotations/metadata
    // Close with endSubsegment
  }
  case Err(e)     -> {
    // Failed to create subsegment
  }
}
```

### Annotating a subsegment

Add key-value annotations for filtering and faceting in the X-Ray console:

```lyric
import AwsXRay

handle = AwsXRay.annotate(handle, "user_id", userId.toString())
handle = AwsXRay.annotate(handle, "request_status", "success")
handle = AwsXRay.annotate(handle, "cache_hit", cacheHit.toString())
```

Annotations are indexed and appear as facets in the X-Ray console — use them for operationally important dimensions.

### Adding metadata

Store arbitrary structured data for debugging:

```lyric
import AwsXRay

handle = AwsXRay.metadata(handle, "request_body", jsonRequest)
handle = AwsXRay.metadata(handle, "database_config", dbConfig.toString())
```

Metadata is not indexed and appears only in detailed trace records — use for raw diagnostic data.

### Closing a subsegment

```lyric
import AwsXRay

AwsXRay.endSubsegment(handle)
```

Closing automatically records the elapsed time and submits the subsegment to X-Ray.

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

### `beginSubsegment(name)`

Create a new X-Ray subsegment with the given name.

```lyric
pub func beginSubsegment(name: in String): Result[SubsegmentHandle, XRayError]
```

| Parameter | Description |
|---|---|
| `name` | Name of the subsegment in X-Ray (appears in console) |

**Returns**: A handle for further operations (annotate, metadata, end).

### `endSubsegment(handle)`

Close a subsegment. Automatic timing is recorded and the subsegment is submitted to X-Ray.

```lyric
pub func endSubsegment(handle: in SubsegmentHandle): Unit
```

### `annotate(handle, key, value)`

Add a string annotation to the subsegment.

```lyric
pub func annotate(
  handle: in SubsegmentHandle,
  key: in String,
  value: in String
): SubsegmentHandle
```

**Returns**: The updated handle (for chaining).

Annotations are **indexed** and appear as facets in the X-Ray console. Use for operationally important dimensions: `user_id`, `status`, `cache_hit`, etc.

### `metadata(handle, key, value)`

Add structured metadata to the subsegment.

```lyric
pub func metadata(
  handle: in SubsegmentHandle,
  key: in String,
  value: in String
): SubsegmentHandle
```

**Returns**: The updated handle (for chaining).

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
import Std.Logging

val log = Std.Logging.getLogger("MyApp.Service")

func processOrder(orderId: in Long): Result[Unit, String] {
  Std.Logging.info(log, "processing order")
  
  match AwsXRay.beginSubsegment("processOrder") {
    case Ok(handle) -> {
      handle = AwsXRay.annotate(handle, "order_id", orderId.toString())
      
      // Do the work
      val result = saveOrder(orderId)
      
      AwsXRay.endSubsegment(handle)
      
      match result {
        case Ok(_)  -> {
          Std.Logging.info(log, "order saved", [Std.Logging.field("order_id", orderId.toString())])
          Ok(Unit)
        }
        case Err(e) -> {
          Std.Logging.error(log, "order failed", [Std.Logging.field("error", e)])
          Err(e)
        }
      }
    }
    case Err(e) -> Err(e.toString())
  }
}
```

## Local development (feature = "local")

When built with the `local` feature, X-Ray operations are no-ops:

- `beginSubsegment` returns `Ok` with a dummy handle
- `annotate` and `metadata` update the dummy handle (no-op)
- `endSubsegment` does nothing

This allows the same code to run locally without AWS X-Ray daemon or permission requirements.

## Production checklist

- ✓ Lambda execution role has `xray:PutTraceSegments` and `xray:PutTelemetryRecords`
- ✓ X-Ray daemon is running in the VPC (if using VPC; Lambda on public subnets uses AWS-managed X-Ray endpoint)
- ✓ X-Ray sampling rules are configured (default: 1 request per second)
- ✓ Subsegment names are meaningful and stable (avoid high-cardinality names like user IDs)
- ✓ Annotations use low-cardinality values (status, outcome, type) for effective filtering
- ✓ Metadata is used for high-volume data (full request bodies, config dumps)

## Package layout

```
lyric-aws-xray/
  lyric.toml                  package manifest
  README.md                   this file
  src/
    xray.l                    AwsXRay  (subsegments, annotations, Tracing aspect)
    _kernel/
      xray_kernel_aws.l       AwsXRay.Kernel.Net @cfg(feature="aws")
      xray_kernel_jvm.l       AwsXRay.Kernel.Net @cfg(feature="jvm")
      xray_kernel_local.l     AwsXRay.Kernel.Net @cfg(feature="local")
  tests/
    *_tests.l                 test modules
```

## See also

- `lyric-lambda` — Lambda runtime adapter; integrates automatically with X-Ray
- `lyric-logging` — Structured logging; complements X-Ray for complete observability
- [AWS X-Ray User Guide](https://docs.aws.amazon.com/xray/) (external reference)
- `docs/35-lambda-library.md` — complete design specification
- `docs/03-decision-log.md` D064 — design decisions
