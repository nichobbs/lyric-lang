# docs/37-grpc-proto-sketch.md — gRPC and Protobuf binding design

**Status:** Unbacked sketch (Q-G-001–Q-G-007 open).  Extends
`docs/27-aspect-libraries.md` and `docs/26-aspects.md` §18 to a new
transport (gRPC / Protobuf).  Will be backed by a decision-log entry
once field-numbering strategy (Q-G-002) and streaming model (Q-G-003)
are resolved.

---

## 1. Scope

This sketch covers:

- Lyric type → Protobuf message / enum / service mapping (code-first)
- Protobuf schema → Lyric record / enum / handler stub generation (spec-first)
- Field number stability: lock-file + optional annotation
- `lyric-grpc` library structure and kernel boundary
- gRPC aspect templates (`RequiresGrpcAuth`, `GrpcCircuitBreaker`)
  sharing `lyric-auth` and `lyric-resilience`
- Async streaming model (forward-looking; requires M1.4 async)

Out of scope:

- gRPC-Web (browser clients) — deferred; needs WASM/JS bridge (docs/35-js-wasm-component-sketch.md)
- gRPC transcoding (HTTP/JSON ↔ gRPC) — deferred to a follow-up sketch
- Custom gRPC interceptors at the kernel level (separate from aspect weaving)

---

## 2. Type mapping

### 2.1 Scalar types

| Lyric | Protobuf |
|---|---|
| `Int` | `int32` |
| `Long` | `int64` |
| `Float` | `double` |
| `Bool` | `bool` |
| `String` | `string` |
| `[Byte]` | `bytes` |

### 2.2 Composite types

| Lyric | Protobuf |
|---|---|
| `record Foo { ... }` | `message Foo { ... }` |
| `enum Bar { A, B, C }` | `enum Bar { A = 0; B = 1; C = 2; }` |
| `enum Bar { A(x: Int), B }` | `message Bar { oneof variant { BarA a = 1; BarB b = 2; } }` + synthetic wrapper messages |
| `[T]` | `repeated T` |
| `Map[String, V]` | `map<string, V>` |
| `Option[T]` | field with `optional` presence (proto3 field presence) |
| distinct type `type X = Long` | same as underlying (`int64`) |
| range subtype `type Age = Int range 0..=150` | `int32` (range enforced at Lyric layer only) |

### 2.3 `Result[T, E]` — mapping to gRPC Status

gRPC has no native `Result` wire type.  Two options:

**Option A — map to gRPC Status (recommended):** `Ok(v)` serialises
the value message and returns `Status.OK`.  `Err(msg)` returns a
non-OK gRPC status code (default: `INTERNAL`) with the error string in
the status message.  Richer errors use `google.rpc.Status` with
`details` (`google.rpc.ErrorInfo`, `google.rpc.BadRequest`, etc.).  The
kernel translates automatically; Lyric handlers stay typed as
`Result[T, String]` and never touch status codes.

**Option B — `oneof` wrapper:** emit a synthetic
`message <Method>Response { oneof result { T value = 1; string error = 2; } }`.
Preserves `Result` shape in the schema but is non-idiomatic for gRPC
clients in other languages (Go, Java, Python all expect status codes).

Default: Option A.  Consumers can opt into Option B per-method with
`@grpc_result_oneof` if they must interoperate with a schema that
already uses this pattern.

### 2.4 Enum with payload → `oneof`

Proto3 enums cannot carry payload.  A Lyric enum with payload variants
maps to a `message` + `oneof`:

```lyric
// Lyric
enum SearchResult {
  Hit(score: Float, id: Long)
  Miss
  Error(reason: String)
}
```

```proto
// Generated .proto
message SearchResult {
  oneof variant {
    SearchResultHit  hit   = 1;
    SearchResultMiss miss  = 2;
    SearchResultError error = 3;
  }
}
message SearchResultHit  { double score = 1; int64 id     = 2; }
message SearchResultMiss { }                                     // empty message
message SearchResultError { string reason = 1; }
```

Spec-first (proto → Lyric): a `message` + `oneof` where every
`oneof` field is itself a message type generates a Lyric `enum` with
payload variants.  A plain proto `enum` generates a Lyric `enum`
without payloads.

---

## 3. Field numbering

### 3.1 Principles

Proto field numbers must be stable across schema versions — changing a
number silently corrupts binary-encoded messages.  Two mechanisms work
together:

1. **Declaration-order default.** On first code-first generation,
   fields are numbered by their position in the `record` (1-indexed).
   This is predictable for new schemas and requires no annotation
   ceremony.

2. **Lock file.** `lyric-grpc.lock` (next to `lyric.toml`, checked into
   version control) stores the canonical `(package, record, field-name) →
   field-number` assignment.  Once written, the lock is the source of
   truth; declaration order is only consulted for *new* fields not yet
   in the lock.

### 3.2 Algorithms

**First generation** (no lock file yet):

```
for each field f at position p (1-indexed):
    if @proto_field(N) present: assign N
    else: assign p
error if any two fields in the same message share a number
write lock file
```

**Subsequent generations** (lock file exists):

```
for each field f in the current record:
    if f is in the lock:
        if @proto_field(N) present and N ≠ lock[f]:
            migrate: lock[f].old_number → reserved; assign N
        else:
            use lock[f]  (annotation optional, must match if present)
    else (new field):
        if @proto_field(N) present: assign N
        else: assign next_available(lock)
            where next_available = lowest positive integer not in
            {all active numbers} ∪ {all reserved numbers}
error if any two active fields share a number
update lock file; tombstoned fields stay with status = reserved
```

**Deleted fields:** their numbers are kept in the lock as
`reserved = true`.  They cannot be reused by a new field without an
explicit `@proto_reserved_ok(N)` acknowledgement annotation (a safety
gate, not a normal workflow).

### 3.3 `@proto_field` use cases

```lyric
record Product {
  id:   Long     // assigned 1 (first field)
  name: String   // assigned 2

  // Inserted between name and price; position 3 is already taken
  // by price in the lock — so without annotation it would get the
  // next available slot (4).  Use @proto_field to match an existing
  // proto definition being migrated into Lyric.
  @proto_field(5)
  description: String

  price: Float   // lock says 3; keeps 3
}
```

```lyric
// Tombstone documentation: price was field 3, now removed.
// @proto_reserved makes the intent explicit and blocks reuse.
@proto_reserved(3)
record ProductV2 {
  id:          Long
  name:        String
  @proto_field(5)
  description: String
  discountPct: Float   // gets next available (4; 3 reserved, 5 taken)
}
```

### 3.4 Lock file format

```toml
# lyric-grpc.lock — generated by `lyric grpc spec`; commit this file.
# Edit manually only with great care; prefer @proto_field annotations.

[messages.Product]
id          = { number = 1 }
name        = { number = 2 }
description = { number = 5 }
price       = { number = 3, reserved = true }   # deleted
```

---

## 4. Service definition

### 4.1 Code-first annotations

```lyric
@grpc_service("ProductService")
package ProductService

import Grpc

@rpc("GetProduct")
pub func getProduct(req: GetProductRequest): Result[Product, String]

@rpc("ListProducts")
pub async func listProducts(req: ListProductsRequest): Stream[Product]

@rpc("UploadImages")
pub async func uploadImages(chunks: Stream[ImageChunk]): Result[UploadSummary, String]

@rpc("Chat")
pub async func chat(msgs: Stream[ChatMessage]): Stream[ChatMessage]
```

Generates:

```proto
service ProductService {
  rpc GetProduct     (GetProductRequest)     returns (Product);
  rpc ListProducts   (ListProductsRequest)   returns (stream Product);
  rpc UploadImages   (stream ImageChunk)     returns (UploadSummary);
  rpc Chat           (stream ChatMessage)    returns (stream ChatMessage);
}
```

### 4.2 Spec-first stubs

`lyric generate grpc <service.proto>` emits:

- One `record` per `message` (with `@proto_field` annotations on every
  field — spec-first always uses explicit numbering).
- One `enum` per proto `enum` (no payload).
- One `enum` with payload variants per `message` that is used only as a
  `oneof` branch type.
- One stub `.l` file per `service` with `@grpc_service` + `@rpc` on
  each stub function body (`{ return Err("not implemented") }`).

---

## 5. Async streaming model

Streaming requires `async func` and a `Stream[T]` type.  These are
planned for M1.4+ (docs/05-implementation-plan.md).  The design is
forward-looking; v1 of `lyric-grpc` ships unary-only and emits a
diagnostic on streaming annotations.  Streaming is tracked under
Q-G-XXX (file before implementation begins) — to be lifted from
SUGGESTION to a v1.x deliverable once `Stream[T]` lands.

### 5.1 `Stream[T]`

```lyric
// lyric-stdlib/std/stream.l (M1.4+)
pub opaque type Stream[T] { ... }

pub func Stream.fromList[T](xs: [T]): Stream[T]
pub func Stream.map[T, U](s: in Stream[T], f: func(T): U): Stream[U]
pub func Stream.filter[T](s: in Stream[T], f: func(T): Bool): Stream[T]
pub func Stream.collect[T](s: in Stream[T]): [T]
```

### 5.2 Streaming return types in aspects

Aspect `around(call) -> ret` with `ret: Stream[T]` requires care:
`call.proceed()` returns a `Stream` lazily; the aspect cannot inspect
individual elements in the current model (only wrap the whole stream or
short-circuit before it starts).  Full per-element interception requires
a future `around(element) -> elem` hook (deferred — Q-G-003).

For the circuit-breaker pattern, short-circuiting *before* the stream
starts is sufficient: if the circuit is open, return an empty stream
(or an error-bearing stream) without calling `proceed`.

---

## 6. `lyric-grpc` library structure

```
lyric-grpc/
  lyric.toml            — deps: stdlib, lyric-auth, lyric-resilience
  src/
    grpc.l              — Grpc package: GrpcContext, GrpcMetadata,
                          GrpcStatus, serve() entry point
    aspects.l           — Grpc.Aspects: RequiresGrpcAuth,
                          GrpcRateLimit, GrpcCircuitBreaker
    _kernel/
      net/grpc_kernel.l — Grpc.Kernel.Net: Grpc.AspNetCore externs
      jvm/grpc_kernel.l — Grpc.Kernel.Jvm: io.grpc externs
```

### 6.1 Core types

```lyric
@runtime_checked
package Grpc

import Std.Core

pub record GrpcMetadata {
  entries: Map[String, String]
}

pub func GrpcMetadata.get(meta: in GrpcMetadata, key: in String): Option[String] { ... }

pub record GrpcContext {
  method:   String
  peer:     String
  metadata: GrpcMetadata
}
```

### 6.2 gRPC aspect templates

`RequiresGrpcAuth` and `GrpcCircuitBreaker` are nearly identical to
`Web.Aspects.RequiresAuth` and `Web.Aspects.HttpCircuitBreaker` but
extract the bearer token from `GrpcContext.metadata` rather than an
HTTP header parameter.  Both delegate to the same `Auth.*` and
`Resilience.*` functions:

```lyric
@runtime_checked
package Grpc.Aspects

import Std.Core
import Grpc
import Auth
import Resilience

@stable(since="0.1")
pub aspect RequiresGrpcAuth {
  config {
    enabled:  Bool   = true
    @sensitive
    jwtSecret: String
    issuer:   String = ""
    audience: String = ""
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val tokenOpt = call.context.metadata.get("authorization")
      match tokenOpt {
        case None ->
          ret = Err(GrpcStatus.unauthenticated("Authorization metadata missing"))
        case Some(bearer) -> {
          val token = if bearer.startsWith("Bearer ") then bearer.substring(7) else bearer
          val ok = Auth.verifyJwt(token, jwtSecret, issuer, audience)
          if ok {
            ret = call.proceed()
          } else {
            ret = Err(GrpcStatus.permissionDenied("Token is invalid or has expired"))
          }
        }
      }
    }
  }
}

@stable(since="0.1")
pub aspect GrpcCircuitBreaker {
  config {
    enabled:          Bool   = true
    name:             String = ""
    failureThreshold: Int    = 5
    cooldownMs:       Int    = 30000
  }

  around(call) -> ret {
    if not enabled {
      ret = call.proceed()
    } else {
      val key = if name.length > 0 then name else call.qualifiedName
      if Resilience.circuitIsOpen(key, cooldownMs) {
        ret = Err(GrpcStatus.unavailable(key + " is temporarily unavailable"))
      } else {
        ret = call.proceed()
        match ret {
          case Ok(_)  -> Resilience.circuitRecordSuccess(key)
          case Err(_) -> Resilience.circuitRecordFailure(key, failureThreshold)
        }
      }
    }
  }
}
```

This demonstrates the key payoff from splitting auth and resilience into
independent libraries: the gRPC aspects share the same verification and
circuit-breaker logic as the HTTP aspects without any code duplication.

---

## 7. Tooling

### 7.1 `lyric grpc spec`

Walks packages annotated with `@grpc_service`, emits a `.proto` file.
Consults and updates `lyric-grpc.lock`.

```sh
lyric grpc spec                       # all @grpc_service packages → grpc.proto
lyric grpc spec --output api.proto    # custom output path
lyric grpc spec --check               # error if generated output differs from committed file
```

### 7.2 `lyric generate grpc`

Generates Lyric stubs from a `.proto` file.

```sh
lyric generate grpc api.proto                     # stubs to src/
lyric generate grpc api.proto --output src/grpc/  # custom output dir
lyric generate grpc api.proto --types-only        # records + enums, no service stubs
```

---

## 8. Kernel boundary

### 8.1 .NET (`Grpc.Kernel.Net`)

```lyric
@cfg(feature = "dotnet")
package Grpc.Kernel.Net

import Grpc

@axiom("Grpc.AspNetCore server host")
extern package Grpc.AspNetCore {
  pub func serve(host: String, port: Int, router: Grpc.ServiceRegistry): Unit
  pub func currentContext(): Grpc.GrpcContext
}
```

### 8.2 JVM (`Grpc.Kernel.Jvm`)

```lyric
@cfg(feature = "jvm")
package Grpc.Kernel.Jvm

import Grpc

@axiom("io.grpc server and context")
extern package io.grpc {
  pub func serve(host: String, port: Int, router: Grpc.ServiceRegistry): Unit
  pub func currentContext(): Grpc.GrpcContext
}
```

---

## 9. Open questions

- **Q-G-001:** `google.rpc.Status` rich error details — should Lyric
  expose a `GrpcError` type (with a code enum and a `details` field)
  instead of `Err(String)` for gRPC handlers?  Richer error types
  allow callers to inspect error codes without string parsing, but
  add a dependency on `google.rpc` well-known types.

- **Q-G-002:** **Field-numbering strategy** — the hybrid approach in
  §3 (declaration order + lock file + `@proto_field` override) is
  proposed but not yet decided.  The key question is whether the lock
  file should live in `lyric-grpc.lock` (one per project) or
  per-`.proto` output file (one per generated schema).  Per-project
  is simpler; per-schema supports projects with multiple independent
  proto outputs.

- **Q-G-003:** Per-element aspect interception for streaming — the
  `around(call) -> ret` model intercepts at the stream boundary, not
  per element.  Rate-limiting per element requires a future
  `around(element) -> elem` hook or a `Stream.map`-based composition.

- **Q-G-004:** `call.context` — the `around` body accesses
  `GrpcContext` via `call.context`.  This requires the aspect
  machinery to bind context data to `call` at weave time.  The
  current `call.*` surface (§6 of docs/26-aspects.md) does not
  include `context`.  Extending it is a language change.

- **Q-G-005:** Reflection-based handler dispatch — the gRPC kernel
  must resolve handler functions by qualified name (same pattern as
  the HTTP kernel).  The JVM bridge needs a stable naming convention
  for Lyric-compiled method descriptors that survives the JVM
  monomorphizer.

- **Q-G-006:** `@proto_reserved` acknowledgement gate — the proposed
  `@proto_reserved_ok(N)` annotation for intentionally reusing a
  tombstoned number is a footgun mitigation.  An alternative is to
  require a `lyric grpc spec --force-reuse-field 3` flag instead of
  an in-source annotation.  The flag approach keeps the .l source clean
  but is harder to code-review.

- **Q-G-007:** gRPC-Web / Connect protocol — supporting browser
  clients without a proxy requires the Connect protocol
  (connectrpc.com) or gRPC-Web.  Both change the HTTP framing and
  are best handled at the kernel layer.  Defer until the WASM/JS
  sketch (docs/35-js-wasm-component-sketch.md) resolves the browser
  target.

---

## 10. References

- Protocol Buffers language guide (proto3) — field numbers and
  reserved fields.
- gRPC status codes — `google.golang.org/grpc/codes`.
- `google.rpc.Status` — rich error details for gRPC.
- `docs/26-aspects.md` §18 — aspect template design; Q-aspects-008
  tracks the `call.context` extension needed by gRPC aspects.
- `docs/27-aspect-libraries.md` — cross-package aspect distribution.
- `docs/31-maven-linking.md` — Maven dependency resolution for JVM
  target (`io.grpc:grpc-java`).
- `docs/35-js-wasm-component-sketch.md` — JS/WASM target; gRPC-Web
  deferred here.
- `lyric-auth/src/auth.l` — transport-agnostic JWT / API-key verification.
- `lyric-resilience/src/resilience.l` — retry and circuit-breaker
  aspect templates.
